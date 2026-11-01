import 'package:peli/data/local/secure_storage.dart';

/// 内存版安全存储：只在本进程里保存键值，方便在主机上测试上层逻辑。
///
/// 生产实现走平台通道（Android Keystore），无法在单元测试里使用。
class FakeSecureStorage implements SecureStorageLike {
  FakeSecureStorage([Map<String, String>? initial])
      : values = <String, String>{...?initial};

  final Map<String, String> values;

  /// 记录调用次数，用于断言"没有多余的 Keystore 往返"。
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read({required String key}) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}
