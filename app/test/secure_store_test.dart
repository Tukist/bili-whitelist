// secure_store 单元测试：断言 createSecureStorage() 返回的实例配置为
// vivo/OriginOS 等国产 ROM 兼容模式（encryptedSharedPreferences=false +
// resetOnError=true）。
//
// 不 mock 整个 FlutterSecureStorage——直接构造实例，断言 aOptions.toMap()
// 透出的配置字段（toMap 是 plugin 9.x 唯一公开字段值的入口，私有字段
// _encryptedSharedPreferences / _resetOnError 无 getter）。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:bili_whitelist_app/services/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('kSecureAndroidOptions：encryptedSharedPreferences=false、'
      'resetOnError=true（vivo 国产 ROM 兼容加固）', () {
    // toMap 是 AndroidOptions 公开字段值的唯一入口（私有字段无 getter）
    final map = kSecureAndroidOptions.toMap();
    expect(map['encryptedSharedPreferences'], 'false');
    expect(map['resetOnError'], 'true');
  });

  test('createSecureStorage() 注入 kSecureAndroidOptions 配置', () {
    final instance = createSecureStorage();
    expect(instance, isA<FlutterSecureStorage>());
    // aOptions 是 FlutterSecureStorage 的 public final 字段
    final map = instance.aOptions.toMap();
    expect(map['encryptedSharedPreferences'], 'false');
    expect(map['resetOnError'], 'true');
  });

  test('多次调用 createSecureStorage() 返回的实例配置一致', () {
    final a = createSecureStorage();
    final b = createSecureStorage();
    expect(a.aOptions.toMap(), b.aOptions.toMap());
    // 两份实例配置完全相等
    expect(a.aOptions.toMap()['encryptedSharedPreferences'], 'false');
    expect(a.aOptions.toMap()['resetOnError'], 'true');
  });
}