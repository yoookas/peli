// APK 凭据加密链路静态验证工具。
//
// 用途：在没有真机的情况下，验证"发布产物里凭据仍然只以密文落盘"这条链路：
//   1. 安全存储插件（flutter_secure_storage）确实随包分发；
//   2. 不再打包 SQLCipher（libsqlcipher.so）—— 账号已改用 Keystore 条目存储；
//   3. 依赖图里既没有 sqflite_sqlcipher 也没有 sqflite；
//   4. 原生库以 STORED 方式打包，且 LOAD 段按 16 KB 对齐（Android 15+ 要求）；
//   5. 明文泄漏哨兵：没有明文 sqlite3 库，asset 里没有 .db / .sqlite 文件。
//
// 用法：
//   dart run tool/verify_apk_encryption.dart [apk 路径]
//
// 说明：这一步不能替代真机验证。"账号确为密文"由平台安全存储保证
// （Keystore 包裹的 AES-GCM），本工具只保证"加密所需的组件确实进了包，
// 而且没有把解密所需的东西或明文数据库一起打进去"。
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

Future<int> main(List<String> args) async {
  final String apkPath = args.isNotEmpty
      ? args.first
      : p.join('build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');

  final File apk = File(apkPath);
  if (!apk.existsSync()) {
    stderr.writeln('找不到 APK：$apkPath（先执行 flutter build apk --release）');
    return 2;
  }

  final Directory work = Directory.systemTemp.createTempSync('memos-apk-verify');
  int failures = 0;
  void check(String label, bool ok, [String? detail]) {
    stdout.writeln('${ok ? '  [OK]  ' : '  [FAIL]'} $label${detail == null ? '' : '  ($detail)'}');
    if (!ok) failures++;
  }

  try {
    stdout.writeln('APK: $apkPath  (${(apk.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB)');
    final Map<String, ZipEntryInfo> entries = unzip(apk.path, work.path);

    final List<File> libs = work
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.so'))
        .toList();

    // -------------------------------------------------------- 1) 安全存储插件
    stdout.writeln('\n1) 账号存储链路：安全存储插件是否随包分发');
    final List<File> appLibs =
        libs.where((File f) => p.basename(f.path) == 'libapp.so').toList();
    final List<File> dexs = work
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => p.basename(f.path).startsWith('classes') && f.path.endsWith('.dex'))
        .toList();
    if (appLibs.isEmpty && dexs.isEmpty) {
      stdout.writeln('  [skip]  找不到 libapp.so / classes*.dex');
    } else {
      final bool inSnapshot =
          appLibs.any((File f) => _strings(f).contains('flutter_secure_storage'));
      final bool inDex = dexs.any((File f) => _strings(f).contains('flutter_secure_storage'));
      check(
        '打包了 flutter_secure_storage（Keystore 保护）',
        inSnapshot || inDex,
        'libapp.so=${appLibs.length}, dex=${dexs.length}',
      );
    }

    // ------------------------------------------------------- 2) 不再有 SQLCipher
    stdout.writeln('\n2) 旧的加密数据库是否已彻底移除');
    final List<File> sqlcipherLibs =
        libs.where((File f) => p.basename(f.path).contains('sqlcipher')).toList();
    check(
      '未打包 libsqlcipher.so',
      sqlcipherLibs.isEmpty,
      sqlcipherLibs.map((File f) => p.basename(f.path)).join(', '),
    );

    // ------------------------------------------------------------ 3) 依赖来源
    stdout.writeln('\n3) 依赖图：不再引入数据库驱动');
    // pub workspace 下 package_config.json 在 workspace 根，而不是 app/ 目录。
    final File? packageConfig = <File>[
      File(p.join('.dart_tool', 'package_config.json')),
      File(p.join('..', '.dart_tool', 'package_config.json')),
    ].where((File f) => f.existsSync()).firstOrNull;
    if (packageConfig == null) {
      stdout.writeln('  [skip]  找不到 package_config.json');
    } else {
      final String json = packageConfig.readAsStringSync();
      check('依赖 flutter_secure_storage', json.contains('flutter_secure_storage'));
      check('未依赖 sqflite_sqlcipher', !json.contains('sqflite_sqlcipher'));
      check('未直接依赖明文 sqflite', !RegExp(r'"name"\s*:\s*"sqflite"').hasMatch(json));
    }

    // -------------------------------------------------- 4) 打包方式与 16 KB 对齐
    stdout.writeln('\n4) 打包方式与 16 KB 页对齐');
    for (final MapEntry<String, ZipEntryInfo> entry in entries.entries) {
      if (!entry.key.startsWith('lib/') || !entry.key.endsWith('.so')) continue;
      final ZipEntryInfo zip = entry.value;
      check(
        '${entry.key} 未压缩（STORED，可 mmap 加载）',
        zip.method == 0,
        zip.method == 0 ? 'STORED' : 'DEFLATE',
      );
    }
    final String? readelf = _findReadelf();
    for (final File lib in libs.where((File f) => f.path.contains('libapp'))) {
      final int maxAlign = readelf == null ? -1 : _maxLoadAlign(readelf, lib.path);
      final String abi = p.basename(p.dirname(lib.path));
      final String name = p.basename(lib.path);
      if (maxAlign < 0) {
        stdout.writeln('  [skip]  $abi/$name 对齐检查（未找到 llvm-readelf）');
      } else {
        check('$abi/$name LOAD 对齐 ${maxAlign ~/ 1024} KB（>= 16 KB）', maxAlign >= 16384);
      }
    }

    // ------------------------------------------------------------ 5) 明文哨兵
    stdout.writeln('\n5) 明文泄漏哨兵');
    final String allSoNames = libs.map((File f) => p.basename(f.path)).join(',');
    check('未把明文 sqlite3 库打进包', !allSoNames.contains('libsqlite3.so'), allSoNames);
    final List<String> databaseAssets = entries.keys
        .where((String name) =>
            !name.startsWith('lib/') &&
            (name.endsWith('.db') || name.endsWith('.sqlite') || name.endsWith('.sqlite3')))
        .toList();
    check('asset 中没有随包分发的数据库文件', databaseAssets.isEmpty, databaseAssets.join(', '));

    stdout.writeln(failures == 0 ? '\n结论：静态检查全部通过。' : '\n结论：$failures 项检查未通过。');
    return failures == 0 ? 0 : 1;
  } finally {
    if (work.existsSync()) work.deleteSync(recursive: true);
  }
}

/// 自带 ZIP 读取：APK 就是 ZIP，但系统工具对 apk 后缀支持不一致
/// （PowerShell 的 Expand-Archive 只认 .zip），所以这里用 Dart 自己解析中央目录。
///
/// 返回每个条目名 → 条目信息，并保留压缩方式（用于验证 STORED 打包）。
Map<String, ZipEntryInfo> unzip(String archive, String destination) {
  final Uint8List bytes = File(archive).readAsBytesSync();
  final ByteData data = ByteData.sublistView(bytes);

  // 1. 从尾部向前找 EOCD 签名 0x06054b50。
  int eocd = -1;
  for (int i = bytes.length - 22; i >= 0 && i > bytes.length - 22 - 65536; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('不是合法的 ZIP/APK：找不到 EOCD');

  final int entryCount = data.getUint16(eocd + 10, Endian.little);
  final int centralOffset = data.getUint32(eocd + 16, Endian.little);

  final Map<String, ZipEntryInfo> result = <String, ZipEntryInfo>{};
  int cursor = centralOffset;
  for (int i = 0; i < entryCount; i++) {
    if (data.getUint32(cursor, Endian.little) != 0x02014b50) break;
    final int method = data.getUint16(cursor + 10, Endian.little);
    final int compressedSize = data.getUint32(cursor + 20, Endian.little);
    final int nameLength = data.getUint16(cursor + 28, Endian.little);
    final int extraLength = data.getUint16(cursor + 30, Endian.little);
    final int commentLength = data.getUint16(cursor + 32, Endian.little);
    final int localOffset = data.getUint32(cursor + 42, Endian.little);
    final String name = String.fromCharCodes(bytes.sublist(cursor + 46, cursor + 46 + nameLength));

    if (!name.endsWith('/')) {
      // 2. 通过本地头定位数据（本地头的 extra 长度可能与中央目录不同）。
      final int localNameLength = data.getUint16(localOffset + 26, Endian.little);
      final int localExtraLength = data.getUint16(localOffset + 28, Endian.little);
      final int dataStart = localOffset + 30 + localNameLength + localExtraLength;
      final Uint8List compressed = bytes.sublist(dataStart, dataStart + compressedSize);
      final Uint8List content = method == 0
          ? compressed
          : Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed));

      final String target = p.join(destination, name.replaceAll('/', p.separator));
      final File out = File(target);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(content);
      result[name] = ZipEntryInfo(path: target, method: method);
    }

    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return result;
}

/// ZIP 条目信息。
class ZipEntryInfo {
  const ZipEntryInfo({required this.path, required this.method});

  final String path;

  /// 0 = STORED（未压缩），8 = DEFLATE。
  final int method;
}

/// 提取文件里的可打印字符串（等价于 strings 命令），用于符号探测。
String _strings(File file) {
  final List<int> bytes = file.readAsBytesSync();
  final StringBuffer buffer = StringBuffer();
  final StringBuffer current = StringBuffer();
  for (final int byte in bytes) {
    if (byte >= 0x20 && byte < 0x7f) {
      current.writeCharCode(byte);
    } else {
      if (current.length >= 4) buffer.writeln(current);
      current.clear();
    }
  }
  if (current.length >= 4) buffer.write(current);
  return buffer.toString();
}

String? _findReadelf() {
  final List<String> candidates = <String>[
    if (Platform.environment['ANDROID_HOME'] != null)
      p.join(Platform.environment['ANDROID_HOME']!, 'ndk'),
    r'D:\Programs\Android\Sdk\ndk',
  ];
  for (final String root in candidates) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity ndk in dir.listSync()) {
      if (ndk is! Directory) continue;
      final File exe = File(p.join(ndk.path, 'toolchains', 'llvm', 'prebuilt',
          'windows-x86_64', 'bin', 'llvm-readelf.exe'));
      if (exe.existsSync()) return exe.path;
    }
  }
  return null;
}

/// 解析 llvm-readelf -lW 输出里所有 LOAD 段的最大对齐值。
int _maxLoadAlign(String readelf, String soPath) {
  final ProcessResult result = Process.runSync(readelf, <String>['-lW', soPath]);
  if (result.exitCode != 0) return -1;
  int maxAlign = 0;
  for (final String line in (result.stdout as String).split('\n')) {
    if (!RegExp(r'\sLOAD\s').hasMatch(line)) continue;
    final List<String> parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) continue;
    final String last = parts.last;
    final int? value = int.tryParse(last.startsWith('0x') ? last.substring(2) : last, radix: 16);
    if (value != null && value > maxAlign) maxAlign = value;
  }
  return maxAlign;
}
