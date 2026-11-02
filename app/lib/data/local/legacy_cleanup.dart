import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secure_storage.dart';

/// 旧版本（v1.0.2 及以前）留下的 SQLCipher 库与它的 DEK。
///
/// v1.0.3 起账号改存平台安全存储，这份库不再被任何代码读取。它本身是密文
/// （没有 DEK 打不开），但留着没有意义：白占空间，还会让"本地到底存了什么"
/// 变得难以解释。因此启动时静默清掉 —— **幂等**，没有残留就什么都不做。
///
/// 删除顺序刻意是"先删文件、再删密钥"：万一文件删不掉（被占用），至少密文还在，
/// 不会出现"密钥没了、密文还在、以后想恢复都恢复不了"的更差状态。
class LegacyDatabaseCleanup {
  const LegacyDatabaseCleanup._();

  /// 旧版本 DatabaseKeyManager 使用的安全存储键。
  static const String keyName = 'memos_db_key_v1';

  /// 旧版本 AppDatabase 使用的库文件名（含 SQLite 的边车文件）。
  static const List<String> fileNames = <String>[
    'memos.db',
    'memos.db-wal',
    'memos.db-shm',
    'memos.db-journal',
  ];
}

/// 清理旧版本残留，返回删掉的文件数。
///
/// 任何一步失败都只影响"这一版没清干净"，绝不抛异常、绝不影响启动。
/// [overrideDirectory] 只给测试用，生产走 [getApplicationSupportDirectory]。
Future<int> purgeLegacyDatabase({
  SecureStorageLike? storage,
  String? overrideDirectory,
}) async {
  int removed = 0;

  try {
    final String directory = overrideDirectory ?? (await getApplicationSupportDirectory()).path;
    for (final String name in LegacyDatabaseCleanup.fileNames) {
      final File file = File(p.join(directory, name));
      try {
        if (!await file.exists()) continue;
        await file.delete();
        removed++;
      } catch (_) {
        // 单个文件删不掉（被占用等）就跳过，下次启动再试。
      }
    }
  } catch (_) {
    // 目录不可用：不是致命问题。
  }

  // 文件都清完了才删密钥；上面若有失败，这里也照删 —— 库反正已经没人读了。
  try {
    await (storage ?? const FlutterSecureStorageAdapter())
        .delete(key: LegacyDatabaseCleanup.keyName);
  } catch (_) {
    // 安全存储不可用时跳过。
  }

  if (removed > 0) {
    // ignore: avoid_print
    print('[cleanup] removed $removed legacy SQLCipher file(s)');
  }
  return removed;
}
