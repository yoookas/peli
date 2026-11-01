import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:peli/data/local/account_store.dart';
import 'package:peli/data/local/secret_store.dart';

import 'support/fake_secure_storage.dart';

/// 账号存储：整份列表存在一个安全存储条目里，这里覆盖读、写、排序与容错。
///
/// 注意：加密本身由平台安全存储负责（Keystore），主机上无法验证，也不在这里假装验证。
void main() {
  AccountStore build(FakeSecureStorage storage) =>
      AccountStore(store: SecretStore(storage: storage));

  AccountRecord account(String id, {String? displayName, DateTime? lastUsedAt}) => AccountRecord(
        id: id,
        baseUrl: 'https://$id.example.com',
        accessToken: 'memos_pat_$id',
        displayName: displayName,
        username: id,
        lastUsedAt: lastUsedAt,
      );

  test('空存储读出来是空列表', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    expect(await build(storage).listAccounts(), isEmpty);
  });

  test('upsert 后能原样读回，且只写一次安全存储', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);

    await store.upsertAccount(account('steven', displayName: 'Steven'));
    final List<AccountRecord> accounts = await store.listAccounts();

    expect(accounts, hasLength(1));
    expect(accounts.single.id, 'steven');
    expect(accounts.single.baseUrl, 'https://steven.example.com');
    expect(accounts.single.accessToken, 'memos_pat_steven');
    expect(accounts.single.displayName, 'Steven');
    expect(accounts.single.title, 'Steven');
    expect(storage.writes, 1);

    // 令牌确实写进了那个条目（落盘时由平台安全存储加密），且内容是合法 JSON。
    final String stored = storage.values[AccountStore.storageKey]!;
    expect(stored, contains('memos_pat_steven'));
    expect(jsonDecode(stored), isA<List<Object?>>());
  });

  test('重新 upsert 同一账号不会清掉上次使用时间', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);

    await store.upsertAccount(account('steven'));
    await store.markAccountUsed('steven');
    final DateTime? afterUse = (await store.listAccounts()).single.lastUsedAt;
    expect(afterUse, isNotNull);

    await store.upsertAccount(account('steven', displayName: 'Steven Renamed'));
    final AccountRecord reread = (await store.listAccounts()).single;
    expect(reread.displayName, 'Steven Renamed');
    expect(reread.lastUsedAt, afterUse, reason: '重新登录不该抹掉"上次使用"');
  });

  test('排序：最近使用在前，从未使用过的排最后', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);

    await store.upsertAccount(account('a'));
    await store.upsertAccount(account('b'));
    await store.upsertAccount(account('c'));
    await store.markAccountUsed('a');

    expect(
      (await store.listAccounts()).map((AccountRecord r) => r.id).toList(),
      <String>['a', 'b', 'c'],
    );

    await store.markAccountUsed('c');
    expect(
      (await store.listAccounts()).map((AccountRecord r) => r.id).toList(),
      <String>['c', 'a', 'b'],
    );
  });

  test('markAccountUsed 对不存在的账号是空操作', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);
    await store.upsertAccount(account('a'));
    final int writesBefore = storage.writes;

    await store.markAccountUsed('nobody');
    expect(storage.writes, writesBefore);
  });

  test('内容损坏时视为没有账号，而不是抛异常卡住启动', () async {
    final FakeSecureStorage storage =
        FakeSecureStorage(<String, String>{AccountStore.storageKey: '{not json'});
    expect(await build(storage).listAccounts(), isEmpty);
  });

  test('字段缺失的条目被跳过，其余照常读出', () async {
    final FakeSecureStorage storage = FakeSecureStorage(<String, String>{
      AccountStore.storageKey: jsonEncode(<Object?>[
        <String, Object?>{'id': 'ok', 'baseUrl': 'https://ok.example.com', 'accessToken': 'x'},
        <String, Object?>{'id': 'broken'},
      ]),
    });

    final List<AccountRecord> accounts = await build(storage).listAccounts();
    expect(accounts, hasLength(1));
    expect(accounts.single.id, 'ok');
  });

  test('deleteAccount 删除指定账号', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);
    await store.upsertAccount(account('a'));
    await store.upsertAccount(account('b'));

    await store.deleteAccount('a');
    expect(
      (await store.listAccounts()).map((AccountRecord r) => r.id).toList(),
      <String>['b'],
    );
  });

  test('并发写不会互相覆盖（markAccountUsed 与 upsert 同时发生）', () async {
    final FakeSecureStorage storage = FakeSecureStorage();
    final AccountStore store = build(storage);
    await store.upsertAccount(account('a'));
    await store.upsertAccount(account('b'));

    await Future.wait(<Future<void>>[
      store.markAccountUsed('a'),
      store.upsertAccount(account('c')),
      store.markAccountUsed('b'),
    ]);

    final List<String> ids =
        (await store.listAccounts()).map((AccountRecord r) => r.id).toList();
    expect(ids, hasLength(3));
    expect(ids.first, anyOf('a', 'b'));
  });
}
