import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:memos_api/memos_api.dart';

import '../data/local/account_store.dart';

/// 应用启动后持有的服务集合。
class AppServices {
  AppServices({
    required this.store,
    required this.accounts,
    this.rejectedAccountIds = const <String>{},
  });

  /// 账号存储（Keystore 保护的条目），随进程存活。
  final AccountStore store;

  /// 已保存的账号（按最近使用排序，见 [AccountStore.listAccounts]）。
  final List<AccountRecord> accounts;

  /// 启动时被服务端明确拒绝（401）的账号 id：凭据已失效，必须重新登录。
  ///
  /// 只收录「确定无效」的账号，网络不通等不确定情况一律不收录 ——
  /// 宁可让用户多等一次 WebView 的加载，也不能因为一次断网把人踢下线。
  final Set<String> rejectedAccountIds;
}

/// 启动流程：从安全存储载入账号。
///
/// **每一步都有超时**：启动链路依赖平台通道（flutter_secure_storage）。
/// 任一通道无响应时，Future 会永久挂起，
/// 表现为"白屏且永远不结束"。真机上确实偶发过这种挂起，因此这里用
/// [_withTimeout] 把"静默挂起"变成"明确的失败提示"，让用户至少知道发生了什么。
Future<AppServices> bootstrapServices() async {
  final Stopwatch watch = Stopwatch()..start();
  void mark(String label) {
    // ignore: avoid_print
    print('[bootstrap] $label  ${watch.elapsedMilliseconds}ms');
  }

  mark('begin');

  // 只做一件事：从 Keystore 保护的条目里读出账号。
  //
  // 之前这里还要取目录、读 DEK、打开 SQLCipher 库 —— 那一段整段挡在首帧前面，
  // 而库里只有一行凭据。现在启动不碰原生库、不碰文件系统。
  final AccountStore store = AccountStore();
  final List<AccountRecord> accounts = await _withTimeout('listAccounts', store.listAccounts());
  mark('accounts=${accounts.length}');

  final Set<String> rejected = await _rejectedAccounts(accounts);
  mark('rejected=${rejected.length}');

  return AppServices(store: store, accounts: accounts, rejectedAccountIds: rejected);
}

/// 校验「最近使用的那个账号」的凭据是否仍然有效。
///
/// ## 为什么必须校验
///
/// 26.10 起访问令牌与账号密码哈希绑定，且短效令牌只有 15 分钟：服务器升级、
/// 改密码、管理员重置、PAT 被删除，都会让本地存着的凭据立刻作废。
///
/// 不校验会发生什么：应用带着失效令牌直接进官方 Web 前端 → 前端 GetCurrentUser
/// 401 → 清空令牌 → 显示登录页。用户在那个页面里登录只会拿到**仅存在于内存**的
/// 令牌（见 `web_app_page.dart` 的 localStorage 覆写，机密键永不落盘），
/// 下次冷启动依旧失效 —— 于是陷入「每次都要重新登录」的死循环，而且再也回不到
/// 能签发 PAT 的原生登录页。
///
/// 因此这里先探一次 `GET /api/auth/me`：只有服务端明确回 401 才判定失效，
/// 其余任何异常（超时、断网、5xx）都保守放行，交由 WebView 自行处理。
Future<Set<String>> _rejectedAccounts(List<AccountRecord> accounts) async {
  if (accounts.isEmpty) return const <String>{};

  final AccountRecord account = accounts.first;
  final Uri? baseUrl = Uri.tryParse(account.baseUrl);
  if (baseUrl == null || account.accessToken.isEmpty) return const <String>{};

  final MemosClient client = MemosClient(baseUrl: baseUrl, accessToken: account.accessToken);
  try {
    // 5 秒上限：健康实例上这是一次 <300ms 的往返；超时只说明「网络不好」，
    // 按不确定处理（放行），不能让启动画面被网络问题拖住。
    await client.getCurrentUser().timeout(const Duration(seconds: 5));
    return const <String>{};
  } on MemosApiException catch (error) {
    return error.isUnauthenticated ? <String>{account.id} : const <String>{};
  } catch (_) {
    // 超时/断网/DNS 失败：凭据是否失效未知，不能据此把用户登出。
    return const <String>{};
  } finally {
    client.close();
  }
}

/// 给启动步骤加超时，把"永久挂起"变成"可诊断的失败"。
Future<T> _withTimeout<T>(String label, Future<T> future) {
  return future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => throw StateError(
      '启动步骤「$label」超过 20 秒未完成，可能是系统服务（钥匙串/文件系统）无响应。'
      '请重启应用；若反复出现，请检查设备是否限制了后台/存储权限。',
    ),
  );
}

/// 启动服务（首次读取时执行一次）。
final FutureProvider<AppServices> appServicesProvider = FutureProvider<AppServices>(
  (Ref ref) => bootstrapServices(),
);

/// 当前激活账号 id（null = 未登录）。
final NotifierProvider<ActiveAccountNotifier, String?> activeAccountIdProvider =
    NotifierProvider<ActiveAccountNotifier, String?>(ActiveAccountNotifier.new);

/// 当前激活账号的选择。
///
/// ## 设计（为什么这样做）
///
/// 1. **自动恢复上次使用的账号**：`bootstrapServices()` 已把账号按
///    最近使用在前（见 [AccountStore.listAccounts]），取第一个即可。
///    绝大多数用户只有一个账号，于是**永远不需要选**。
/// 2. **显式选择优先**：用户切换账号后 `set()` 立即写库（`markAccountUsed`），
///    下次冷启动恢复的就是他最后选的那个。
/// 3. **上次用的账号被删除时**：它已不在排序结果里，自动落到下一个，不会卡在空状态。
/// 4. **上次用的账号凭据失效时**（服务器升级、改密码、PAT 被删）：它被记进
///    [AppServices.rejectedAccountIds]，这里跳过它 —— 于是落到登录页重新签发 PAT，
///    而不是带着死令牌进 WebView 后只能看着官方登录页反复登录（详见 [_rejectedAccounts]）。
///
/// 放在 `build()` 里同步推导而不是异步查库：`AppBootstrap` 已经等
/// `appServicesProvider` 就绪才构建 `MemosApp`，此刻账号列表就在手上，
/// 同步取值可避免"首帧闪一下配置页"。
class ActiveAccountNotifier extends Notifier<String?> {
  @override
  String? build() {
    // 冷启动：取最近使用、且凭据仍然有效的账号（列表已按 last_used_at 排序）。
    final AsyncValue<AppServices> services = ref.watch(appServicesProvider);
    return services.maybeWhen(
      data: (AppServices value) => value.accounts
          .where((AccountRecord account) => !value.rejectedAccountIds.contains(account.id))
          .firstOrNull?.id,
      orElse: () => null,
    );
  }

  /// 切换当前账号，并持久化"这是最后使用的账号"。
  void set(String? accountId) {
    state = accountId;
    if (accountId == null) return;
    final AsyncValue<AppServices> services = ref.read(appServicesProvider);
    services.whenData((AppServices value) {
      // 写入失败不阻塞 UI：最坏情况是下次启动恢复到上一个账号。
      unawaited(value.store.markAccountUsed(accountId));
    });
  }
}

/// 当前激活账号。
final Provider<AccountRecord?> activeAccountProvider = Provider<AccountRecord?>((Ref ref) {
  final AsyncValue<AppServices> services = ref.watch(appServicesProvider);
  final String? id = ref.watch(activeAccountIdProvider);
  return services.maybeWhen(
    data: (AppServices value) => value.accounts.where((AccountRecord a) => a.id == id).firstOrNull,
    orElse: () => null,
  );
});

/// 登录：用户名密码 → 长效 PAT → 存进平台安全存储。
///
/// 这是本客户端**唯一**与 memos API 直接交互的地方：拿到 PAT 之后，所有业务请求
/// 都由页面里的官方前端自己发起，本应用只在 WebView 里替它补上凭据。
class SessionController {
  SessionController(this._ref);

  final Ref _ref;

  AppServices get _services => _ref.read(appServicesProvider).requireValue;

  Future<AccountRecord> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final MemosClient client = MemosClient(baseUrl: Uri.parse(baseUrl));
    try {
      final SignInResult session = await client.signIn(username: username, password: password);
      client.accessToken = session.accessToken;

      // 版本校验：本项目只支持 memos 0.31.0 及以上的 v1 API。
      final InstanceProfile profile = await client.getProfile();
      if (!profile.isSupported) {
        throw MemosApiException(
          '该实例版本为 ${profile.version}，本客户端要求 0.31.0 及以上',
        );
      }

      // 优先换取长效 PAT —— 这是能「登录一次、长期免登录」的唯一凭据。
      //
      // 退路（保留短效 token）在 26.10 上是**不可接受**的降级：短效令牌只有 15 分钟
      // 且与密码哈希绑定，意味着用户 15 分钟后、或下次冷启动时就又得登录。
      // 因此这里把失败原因打出来，便于定位（正常情况下不应走到这条分支）。
      String token = session.accessToken;
      try {
        token = await client.createPersonalAccessToken(
          userId: session.user.id,
          description: 'Android 客户端',
        );
      } on MemosApiException catch (error) {
        // ignore: avoid_print
        print('[auth] PAT 创建失败，只能退回短效令牌（会话将在 15 分钟后失效）：$error');
      }

      final AccountRecord account = AccountRecord(
        id: session.user.id,
        baseUrl: baseUrl,
        accessToken: token,
        displayName: session.user.displayName,
        username: session.user.username.isEmpty ? null : session.user.username,
      );
      await _services.store.upsertAccount(account);
      _services.accounts
        ..removeWhere((AccountRecord a) => a.id == account.id)
        ..add(account);
      _ref.read(activeAccountIdProvider.notifier).set(account.id);
      return account;
    } finally {
      client.close();
    }
  }
}

final Provider<SessionController> sessionControllerProvider =
    Provider<SessionController>(SessionController.new);
