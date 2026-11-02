import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:memos_api/memos_api.dart';
import 'package:peli/data/local/account_store.dart';
import 'package:peli/data/local/secret_store.dart';
import 'package:peli/state/providers.dart';

import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

/// 登录整条链路：API → 版本守门 → 签 PAT → 落盘 → 更新进程内缓存 → 选中账号。
///
/// 为什么单独测这一层：v1.0.3 的固定长度列表 bug 死在"更新缓存"这一步 ——
/// AccountStore 自己的测试全绿，登录却崩在调用方的写回路径上。
void main() {
  late FakeSecureStorage storage;
  late AccountStore store;
  late AppServices services;

  setUp(() {
    storage = FakeSecureStorage();
    store = AccountStore(store: SecretStore(storage: storage));
    services = AppServices(store: store, accounts: const <AccountRecord>[]);
  });

  ProviderContainer buildContainer(FakeHttpClient httpClient) {
    final ProviderContainer container = ProviderContainer(
      // 类型由参数推断（Riverpod 3 里 Override 这个类型名不总是可引用）。
      overrides: [
        appServicesProvider.overrideWith((Ref ref) => services),
        sessionControllerProvider.overrideWith(
          (Ref ref) => SessionController(
            ref,
            clientFactory: (Uri baseUrl) => MemosClient(baseUrl: baseUrl, httpClient: httpClient),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 默认全绿的服务端：登录、实例信息、建 PAT 三个端点。
  FakeHttpClient happyServer({String version = '26.10.0-rc.2', bool patSucceeds = true}) {
    return FakeHttpClient(<String, http.Response Function(http.Request request)>{
      '/api/auth/signin': (http.Request request) => jsonOk(<String, Object?>{
            'user': <String, Object?>{
              'name': 'users/steven',
              'username': 'steven',
              'displayName': 'Steven',
            },
            'accessToken': 'jwt-token',
          }),
      '/api/instance/profile': (http.Request request) =>
          jsonOk(<String, Object?>{'version': version}),
      '/api/users/steven/personalAccessTokens': (http.Request request) => patSucceeds
          ? jsonOk(<String, Object?>{'token': 'memos_pat_abc'})
          : jsonError(500, 13, 'boom'),
    });
  }

  Future<AccountRecord> signIn(ProviderContainer container) =>
      container.read(sessionControllerProvider).signIn(
            baseUrl: 'https://memos.example.com',
            username: 'steven',
            password: 'pw',
          );

  test('登录成功：签出 PAT、写盘、更新缓存并选中账号', () async {
    final FakeHttpClient httpClient = happyServer();
    final ProviderContainer container = buildContainer(httpClient);
    await container.read(appServicesProvider.future);

    final AccountRecord account = await signIn(container);

    expect(account.id, 'steven');
    expect(account.accessToken, 'memos_pat_abc', reason: '应当持有长效 PAT 而不是短效令牌');

    // 1) 落盘：下次冷启动靠它免登录
    final List<AccountRecord> stored = await store.listAccounts();
    expect(stored.single.accessToken, 'memos_pat_abc');

    // 2) 进程内缓存 —— v1.0.3 就是在这里抛 Cannot remove from a fixed-length list
    final AppServices live = container.read(appServicesProvider).requireValue;
    expect(live.accounts.map((AccountRecord a) => a.id).toList(), <String>['steven']);
    expect(live.accounts.single.accessToken, 'memos_pat_abc');

    // 3) 当前账号
    expect(container.read(activeAccountIdProvider), 'steven');
    expect(container.read(activeAccountProvider)?.accessToken, 'memos_pat_abc');

    // 4) 端点使用正确（26.10 的 /api，不是 /api/v1）
    expect(
      httpClient.paths,
      <String>['/api/auth/signin', '/api/instance/profile', '/api/users/steven/personalAccessTokens'],
    );
  });

  test('重复登录只保留一条记录（缓存与库里都不重复）', () async {
    final ProviderContainer container = buildContainer(happyServer());
    await container.read(appServicesProvider.future);

    await signIn(container);
    await signIn(container);

    final AppServices live = container.read(appServicesProvider).requireValue;
    expect(live.accounts, hasLength(1));
    expect(await store.listAccounts(), hasLength(1));
  });

  test('实例版本低于 0.31.0：拒绝登录，不写入任何账号', () async {
    final ProviderContainer container = buildContainer(happyServer(version: '0.30.0'));
    await container.read(appServicesProvider.future);

    await expectLater(
      signIn(container),
      throwsA(
        isA<MemosApiException>().having((MemosApiException e) => e.message, 'message', contains('0.31.0')),
      ),
    );

    expect(await store.listAccounts(), isEmpty);
    expect(container.read(appServicesProvider).requireValue.accounts, isEmpty);
  });

  test('用户名或密码错误：抛出未认证，不写入账号', () async {
    final ProviderContainer container = buildContainer(
      FakeHttpClient(<String, http.Response Function(http.Request request)>{
        '/api/auth/signin': (http.Request request) => jsonError(401, 16, 'authentication required'),
      }),
    );
    await container.read(appServicesProvider.future);

    await expectLater(
      signIn(container),
      throwsA(isA<MemosApiException>().having(
        (MemosApiException e) => e.isUnauthenticated,
        'isUnauthenticated',
        isTrue,
      )),
    );

    expect(await store.listAccounts(), isEmpty);
  });

  test('PAT 创建失败时退回短效令牌，但登录不失败', () async {
    final ProviderContainer container = buildContainer(happyServer(patSucceeds: false));
    await container.read(appServicesProvider.future);

    final AccountRecord account = await signIn(container);

    expect(account.accessToken, 'jwt-token');
    expect((await store.listAccounts()).single.accessToken, 'jwt-token');
    expect(container.read(activeAccountIdProvider), 'steven');
  });
}
