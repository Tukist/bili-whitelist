/// flutter_secure_storage 统一 AndroidOptions 封装（vivo 等国产 ROM 兼容加固）。
///
/// 背景：flutter_secure_storage 9.2.4 在 Android 上有两套加密实现——
/// - `encryptedSharedPreferences: true`（默认开在部分用法里）：走 Jetpack
///   Security（Tink + Keystore）。vivo OriginOS 等国产 ROM 的 Keystore
///   实现与 Tink 不完全兼容，写入/读取会抛 KeyStoreException /
///   SecurityException / InvalidKeyException 等 PlatformException，
///   表现为「配置保存失败」「登录态保存失败」。
/// - `encryptedSharedPreferences: false`：走插件 9.x 自研的 Keystore
///   加密（RSA 包 AES key + SharedPreferences 落密文），对 ROM 兼容性
///   更好。注意：9.2.4 的 AndroidOptions 默认值本身就是 false，这里显式
///   声明是为锁定行为、避免后续版本默认值变化。
///
/// 另外补 `resetOnError: true`：当 Keystore 里解不出历史密钥（典型场景：
///   卸载重装后系统没清理旧 SharedPreferences，或备份恢复把旧密文带回来）
///   时，插件自动清空本地密文而不是抛 PlatformException 让读写永久失败。
///   副作用是这种场景下本地已存数据会清空（回到「未配置」态，用户重配
///   一次即可），比「永久坏掉」可接受得多。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全 App 统一的 Android secure storage 选项。
///
/// - encryptedSharedPreferences: false → 插件自研 Keystore 加密（ROM 兼容）
/// - resetOnError: true → 密钥失效时自动重置本地密文，避免永久抛异常
const AndroidOptions kSecureAndroidOptions = AndroidOptions(
  encryptedSharedPreferences: false,
  resetOnError: true,
);

/// 创建统一配置的 secure storage 实例（测试仍可注入自定义实例）。
FlutterSecureStorage createSecureStorage() =>
    const FlutterSecureStorage(aOptions: kSecureAndroidOptions);
