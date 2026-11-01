import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 平台安全存储的最小接口。
///
/// 抽出接口有两个目的：
/// - 让上层（[SecretStore]、[AccountStore]）不依赖插件实现，可在主机上测试；
/// - 把"密钥保护到底由谁负责"这件事收敛到一个文件里。
///
/// Android 上由 Keystore 保护（RSA-OAEP 包裹密钥 + AES-GCM 加密内容，
/// 密钥不可导出、不参与云备份）；iOS/macOS 走 Keychain。
abstract interface class SecureStorageLike {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

/// 生产实现：flutter_secure_storage。
class FlutterSecureStorageAdapter implements SecureStorageLike {
  const FlutterSecureStorageAdapter([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
