import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'secure_storage.dart';

/// 机密条目的持久化：只以**密文**形式落盘。
///
/// 这里保存两类东西：
/// - **账号**（实例地址 + 长效 PAT），见 `AccountStore`；
/// - **图片缓存密钥**，见 [SessionSecrets]。
///
/// 条目由 flutter_secure_storage 保管，在 Android 上由 Keystore 保护
/// （RSA-OAEP 包裹密钥 + AES-GCM 加密内容；Keystore 密钥不可导出、不参与备份），
/// 因此随设备备份一起被提取的密文无法解密。
///
/// ## 为什么不再用 SQLCipher
///
/// 之前账号存在 SQLCipher 加密库里。但那套东西（加载 libsqlcipher.so、打开库、
/// 读 DEK、解第一页）在每次冷启动都要完整走一遍，而库里**只有一行**凭据 ——
/// 用加密数据库装一行数据，付出的是原生库加载、文件 IO、schema 与迁移维护，
/// 换来的额外保护却很有限：SQLCipher 的 DEK 本身也存在 Keystore 里，
/// 两者的根锁是同一把。改成一个 Keystore 条目后：启动不再碰原生库，
/// 也不再出现"库在、密钥丢 → 拒绝启动"的死局（密钥丢 = 读到 null = 未登录）。
class SecretStore {
  SecretStore({SecureStorageLike? storage})
      : _storage = storage ?? const FlutterSecureStorageAdapter();

  final SecureStorageLike _storage;

  /// 读取字节条目；不存在或数据损坏时返回 null（由调用方决定如何重建）。
  Future<Uint8List?> readBytes(String key) async {
    final String? encoded = await readText(key);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } catch (_) {
      // 数据损坏：当作不存在，由调用方重建。
      return null;
    }
  }

  /// 写入字节条目。
  Future<void> writeBytes(String key, Uint8List value) => writeText(key, base64Encode(value));

  /// 读取文本条目；不存在时返回 null。
  ///
  /// 内容本身已由平台安全存储加密，是否需要第二层编码（例如字节走 base64）
  /// 由调用方决定。
  Future<String?> readText(String key) async {
    final String? value = await _storage.read(key: key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> writeText(String key, String value) => _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 运行时会话机密：附件图片的缓存密钥。
///
/// 为什么需要这一层：图片密文存在 WebView 的 IndexedDB 里，页面启动时必须拿到密钥
/// 才能解密（`web_app_page.dart` 以 `window.__memosImageKey` 注入，**只经内存**）。
/// 若把密钥明文留在 IndexedDB，加密就毫无意义 —— 所以密钥只在本类（Keystore 保护
/// 的条目）与进程内存里，密文与密钥分开存放。
class SessionSecrets {
  SessionSecrets({required this.accountId, SecretStore? store})
      : _store = store ?? SecretStore();

  final String accountId;
  final SecretStore _store;

  String get _imageKeyKey => 'session.imageKey.$accountId';

  /// 取得（必要时随机生成）图片缓存密钥：AES-GCM 用的 32 字节。
  Future<Uint8List> imageCacheKey() async {
    final Uint8List? existing = await _store.readBytes(_imageKeyKey);
    if (existing != null && existing.length == 32) return existing;
    final Uint8List fresh = _randomBytes(32);
    await _store.writeBytes(_imageKeyKey, fresh);
    return fresh;
  }

  /// 图片密钥的 base64 形式（直接喂给页面的 Web Crypto）。
  Future<String> imageCacheKeyBase64() async =>
      base64Encode(await imageCacheKey());

  static Uint8List _randomBytes(int length) {
    final Random random = Random.secure();
    final Uint8List bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}
