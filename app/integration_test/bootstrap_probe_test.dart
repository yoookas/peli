import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peli/data/local/account_store.dart';
import 'package:peli/data/local/secret_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 分步复现应用启动链路，逐步计时以定位"卡在哪一步"。
///
/// 现在启动链路只有一步重活：从平台安全存储读出账号（见 `bootstrapServices`）。
/// 之前那套「取目录 → 读 DEK → 打开 SQLCipher → 查表」已经整个删掉了。
///
/// 跑法：`flutter test integration_test/bootstrap_probe_test.dart -d <deviceId>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> step(String label, Future<void> Function() body) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      await body().timeout(const Duration(seconds: 20));
      // ignore: avoid_print
      print('STEP_OK   $label  ${watch.elapsedMilliseconds}ms');
    } catch (error) {
      // ignore: avoid_print
      print('STEP_FAIL $label  ${watch.elapsedMilliseconds}ms  $error');
      rethrow;
    }
  }

  testWidgets('启动链路分步探测', (WidgetTester tester) async {
    late Directory support;

    await step('getApplicationSupportDirectory', () async {
      support = await getApplicationSupportDirectory();
      // ignore: avoid_print
      print('  support=${support.path}');
    });

    await step('AccountStore.listAccounts()（启动唯一的重活）', () async {
      final Stopwatch watch = Stopwatch()..start();
      final List<AccountRecord> accounts = await AccountStore().listAccounts();
      // ignore: avoid_print
      print('  accounts=${accounts.length} took=${watch.elapsedMilliseconds}ms'
          '${accounts.isEmpty ? '' : ' first=${accounts.first.id}'}');
    });

    await step('secure_storage 裸读 accounts.v1', () async {
      const FlutterSecureStorage storage = FlutterSecureStorage();
      final String? value = await storage.read(key: AccountStore.storageKey);
      // ignore: avoid_print
      print('  accounts_entry=${value == null ? 'null' : 'len=${value.length}'}');
    });

    await step('SessionSecrets.imageCacheKeyBase64()', () async {
      final Stopwatch watch = Stopwatch()..start();
      final String key = await SessionSecrets(accountId: 'probe').imageCacheKeyBase64();
      // ignore: avoid_print
      print('  image_key_len=${key.length} took=${watch.elapsedMilliseconds}ms');
    });

    await step('shared_prefs 目录检查（flutter_secure_storage 落盘位置）', () async {
      final Directory prefs = Directory(p.join(support.parent.path, 'shared_prefs'));
      if (await prefs.exists()) {
        for (final FileSystemEntity entity in prefs.listSync()) {
          // ignore: avoid_print
          print('  pref: ${p.basename(entity.path)}');
        }
      } else {
        // ignore: avoid_print
        print('  shared_prefs 不存在');
      }
    });
  });
}
