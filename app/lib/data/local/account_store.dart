import 'dart:async';
import 'dart:convert';

import 'secret_store.dart';

/// 账号记录 —— 本地唯一持久化的业务数据。
///
/// 当前架构下本地只存"实例地址 + 长效 PAT"：界面是官方 Web 前端，凭据靠页面注入，
/// 因此不需要在本地保存 memo、附件或同步状态。
class AccountRecord {
  const AccountRecord({
    required this.id,
    required this.baseUrl,
    required this.accessToken,
    this.displayName,
    this.username,
    this.lastUsedAt,
  });

  /// 账号 id（等于 memos 用户 id，或用户名）。
  final String id;

  /// 实例根地址，例如 `https://memos.example.com`。
  final String baseUrl;

  /// 长效 Personal Access Token。
  final String accessToken;

  /// 服务端返回的显示名（可能为空）。
  final String? displayName;

  /// 用户名（显示名缺失时的回退）。
  final String? username;

  /// 最后一次使用的时刻（UTC）。
  ///
  /// 存在的意义：启动时据此**自动恢复**上次用的账号，用户不必每次冷启动都重新选。
  /// 为 null 表示从未使用过。
  final DateTime? lastUsedAt;

  /// 登录页「已保存实例」里显示的名字：显示名 → 用户名 → 主机名。
  String get title {
    final String? name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final String? user = username?.trim();
    if (user != null && user.isNotEmpty) return user;
    return Uri.tryParse(baseUrl)?.host ?? baseUrl;
  }

  AccountRecord copyWith({DateTime? lastUsedAt}) => AccountRecord(
        id: id,
        baseUrl: baseUrl,
        accessToken: accessToken,
        displayName: displayName,
        username: username,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );
}

/// 账号的持久化：**整份列表作为一个 JSON 条目**存进平台安全存储。
///
/// ## 为什么不用数据库
///
/// 本地只有"实例地址 + 长效 PAT"这一行数据，用 SQLCipher 装它意味着每次冷启动
/// 都要加载原生库、打开库文件、解页 —— 首帧被这段串行工作挡住。改成一个
/// Keystore 保护的条目后，启动只需要一次安全存储读取（和本来就有的图片密钥同源），
/// 加密强度不变（根锁同样是 Keystore），而 schema、迁移、库损坏这些概念直接消失。
///
/// ## 为什么整份存一个 key
///
/// flutter_secure_storage 的每次读写都是一次 Keystore 往返。多账号时逐条存取会
/// 变成 N 次往返；整份序列化只花一次。账号数量是个位数，这个取舍没有悬念。
///
/// ## 写并发
///
/// 读-改-写之间用 [_serialized] 串行化：`markAccountUsed` 是 fire-and-forget
/// （见 `ActiveAccountNotifier.set`），与登录时的 `upsertAccount` 可能重叠，
/// 不串行会丢更新。
class AccountStore {
  AccountStore({SecretStore? store}) : _store = store ?? SecretStore();

  /// 存储键。带 `.v1` 后缀，便于将来识别旧格式。
  static const String storageKey = 'accounts.v1';

  final SecretStore _store;

  Future<void> _tail = Future<void>.value();

  /// 把读-改-写串成一条链，避免并发写互相覆盖。
  Future<T> _serialized<T>(Future<T> Function() body) async {
    final Completer<void> done = Completer<void>();
    final Future<void> previous = _tail;
    _tail = done.future;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
    }
  }

  /// 全部账号，**最近使用的排在最前**。
  ///
  /// 排序而非额外记录"当前账号"：启动时取第一个即可，少一次往返，
  /// 而且天然处理了"上次用的账号已被删除"的情况。
  ///
  /// **必须返回可增长列表**：返回值会被 `AppServices.accounts` 当成进程内的账号
  /// 缓存，登录成功后调用方会原地 `removeWhere + add` 更新它。曾经这里写成
  /// `toList(growable: false)`，结果登录时直接抛
  /// "Unsupported operation: Cannot remove from a fixed-length list" ——
  /// 账号其实已经落盘，但界面停在错误提示上。
  Future<List<AccountRecord>> listAccounts() => _serialized(() async {
        final List<_StoredAccount> stored = await _read();
        stored.sort(_compare);
        return stored.map((_StoredAccount a) => a.record).toList();
      });

  /// 写入或更新账号。
  ///
  /// 与之前数据库实现同样的语义：**整条覆盖，但保留**已有的 `lastUsedAt`
  /// 和 `createdAt` —— 否则每次重新登录都会把"上次使用的账号"抹掉，
  /// 用户又得重新选一次。
  Future<void> upsertAccount(AccountRecord account) => _serialized(() async {
        final List<_StoredAccount> stored = await _read();
        final int index = stored.indexWhere((_StoredAccount a) => a.record.id == account.id);
        final DateTime createdAt =
            index == -1 ? DateTime.now().toUtc() : stored[index].createdAt;
        final DateTime? lastUsedAt =
            account.lastUsedAt ?? (index == -1 ? null : stored[index].record.lastUsedAt);
        final _StoredAccount updated = _StoredAccount(
          record: account.copyWith(lastUsedAt: lastUsedAt),
          createdAt: createdAt,
        );
        if (index == -1) {
          stored.add(updated);
        } else {
          stored[index] = updated;
        }
        await _write(stored);
      });

  /// 记录"这个账号刚被使用"，供下次冷启动自动恢复。
  Future<void> markAccountUsed(String id) => _serialized(() async {
        final List<_StoredAccount> stored = await _read();
        final int index = stored.indexWhere((_StoredAccount a) => a.record.id == id);
        if (index == -1) return;
        stored[index] = _StoredAccount(
          record: stored[index].record.copyWith(lastUsedAt: DateTime.now().toUtc()),
          createdAt: stored[index].createdAt,
        );
        await _write(stored);
      });

  /// 删除账号（例如"清除本地数据"）。
  Future<void> deleteAccount(String id) => _serialized(() async {
        final List<_StoredAccount> stored = await _read();
        final int before = stored.length;
        stored.removeWhere((_StoredAccount a) => a.record.id == id);
        if (stored.length != before) await _write(stored);
      });

  // ---------------------------------------------------------------------------
  // JSON
  // ---------------------------------------------------------------------------

  Future<List<_StoredAccount>> _read() async {
    final String? raw = await _store.readText(storageKey);
    if (raw == null || raw.isEmpty) return <_StoredAccount>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // 内容损坏：当作没有账号，让用户重新登录，而不是卡在启动阶段。
      return <_StoredAccount>[];
    }
    if (decoded is! List) return <_StoredAccount>[];
    final List<_StoredAccount> result = <_StoredAccount>[];
    for (final Object? item in decoded) {
      final _StoredAccount? account = _StoredAccount.fromJson(item);
      if (account != null) result.add(account);
    }
    return result;
  }

  Future<void> _write(List<_StoredAccount> accounts) => _store.writeText(
        storageKey,
        jsonEncode(accounts.map((_StoredAccount a) => a.toJson()).toList()),
      );

  /// 未使用过的排最后，其余按最近使用倒序；同刻按创建时间正序。
  static int _compare(_StoredAccount a, _StoredAccount b) {
    final DateTime? left = a.record.lastUsedAt;
    final DateTime? right = b.record.lastUsedAt;
    if (left == null && right != null) return 1;
    if (left != null && right == null) return -1;
    if (left != null && right != null) {
      final int byUse = right.compareTo(left);
      if (byUse != 0) return byUse;
    }
    return a.createdAt.compareTo(b.createdAt);
  }
}

/// 落盘形态：账号 + 创建时间（后者只用于排序，不对外暴露）。
class _StoredAccount {
  const _StoredAccount({required this.record, required this.createdAt});

  final AccountRecord record;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': record.id,
        'baseUrl': record.baseUrl,
        'accessToken': record.accessToken,
        'displayName': record.displayName,
        'username': record.username,
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'lastUsedAt': record.lastUsedAt?.toUtc().millisecondsSinceEpoch,
      };

  static _StoredAccount? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final Object? id = value['id'];
    final Object? baseUrl = value['baseUrl'];
    final Object? accessToken = value['accessToken'];
    if (id is! String || baseUrl is! String || accessToken is! String) return null;
    final Object? created = value['createdAt'];
    final Object? used = value['lastUsedAt'];
    return _StoredAccount(
      record: AccountRecord(
        id: id,
        baseUrl: baseUrl,
        accessToken: accessToken,
        displayName: _asString(value['displayName']),
        username: _asString(value['username']),
        lastUsedAt: used is int ? DateTime.fromMillisecondsSinceEpoch(used, isUtc: true) : null,
      ),
      createdAt: created is int
          ? DateTime.fromMillisecondsSinceEpoch(created, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// 宽容地取字符串：类型不对就当没有 —— 一条坏数据不该把启动打断。
  static String? _asString(Object? value) => value is String ? value : null;
}
