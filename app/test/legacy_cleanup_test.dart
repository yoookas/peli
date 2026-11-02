import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peli/data/local/legacy_cleanup.dart';

import 'support/fake_secure_storage.dart';

/// 旧版本残留清理：幂等、非致命、只动自己那几样东西。
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('peli-legacy-cleanup');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  File file(String name) => File(p.join(directory.path, name));

  test('删掉旧库文件与 DEK，返回删除的文件数', () async {
    for (final String name in LegacyDatabaseCleanup.fileNames) {
      await file(name).writeAsString('ciphertext');
    }
    final FakeSecureStorage storage =
        FakeSecureStorage(<String, String>{LegacyDatabaseCleanup.keyName: 'base64-dek'});

    final int removed =
        await purgeLegacyDatabase(storage: storage, overrideDirectory: directory.path);

    expect(removed, LegacyDatabaseCleanup.fileNames.length);
    for (final String name in LegacyDatabaseCleanup.fileNames) {
      expect(file(name).existsSync(), isFalse, reason: name);
    }
    expect(storage.values.containsKey(LegacyDatabaseCleanup.keyName), isFalse);
  });

  test('没有残留时不报错、返回 0', () async {
    final FakeSecureStorage storage = FakeSecureStorage();

    final int removed =
        await purgeLegacyDatabase(storage: storage, overrideDirectory: directory.path);

    expect(removed, 0);
  });

  test('目录不存在也不抛异常（下次启动再试）', () async {
    final FakeSecureStorage storage = FakeSecureStorage();

    final int removed = await purgeLegacyDatabase(
      storage: storage,
      overrideDirectory: p.join(directory.path, 'not-there'),
    );

    expect(removed, 0);
  });

  test('只删自己的文件，目录里其它东西原样保留', () async {
    final File keep = await file('keep.txt').writeAsString('do not touch');
    await file('memos.db').writeAsString('ciphertext');

    final int removed = await purgeLegacyDatabase(
      storage: FakeSecureStorage(),
      overrideDirectory: directory.path,
    );

    expect(removed, 1);
    expect(keep.existsSync(), isTrue);
    expect(await keep.readAsString(), 'do not touch');
  });

  test('重复执行是幂等的', () async {
    await file('memos.db').writeAsString('ciphertext');
    final FakeSecureStorage storage = FakeSecureStorage();

    expect(await purgeLegacyDatabase(storage: storage, overrideDirectory: directory.path), 1);
    expect(await purgeLegacyDatabase(storage: storage, overrideDirectory: directory.path), 0);
  });
}
