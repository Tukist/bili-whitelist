// 模拟器会话注入（仅本机手动运行，真实设备 storage）：
//   flutter test integration_test/seed_session_test.dart -d emulator-5554 \
//     --dart-define=SEED_MODE=long|near|clear
//
// 用途：给「启动静默/续期触发」场景造登录态——
//   - SEED_MODE=clear：删除 bili_sessdata/bili_jct/bili_refresh_token（匿名）
//   - SEED_MODE=long：写入未来 +30 天有效期的合成 SESSDATA（无 refresh_token）
//   - SEED_MODE=near：写入未来 +10 天 SESSDATA + jct + refresh_token
//     （进入"有 refresh_token → 15 天提前续期"窗口，续期请求会真实发出；
//      token 是假凭据，服务端回 -101，正好验证「接口 -101 记录但流程不崩」）
// 注入完成后宿主用 adb 冷启动 App + logcat/uiautomator dump 取证。
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/services/secure_store.dart';

const _mode = String.fromEnvironment('SEED_MODE', defaultValue: 'clear');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('seed bili session ($_mode)', (tester) async {
    const storage = FlutterSecureStorage(aOptions: kSecureAndroidOptions);
    const sessKey = 'bili_sessdata';
    const jctKey = 'bili_jct';
    const rtKey = 'bili_refresh_token';

    if (_mode == 'clear') {
      await storage.delete(key: sessKey);
      await storage.delete(key: jctKey);
      await storage.delete(key: rtKey);
      debugPrint('[seed] SEED_MODE=clear 已清空 bili 会话');
    } else {
      // 合成 SESSDATA：`uid,<过期Unix秒>,md5...`（结构可被 sessdataExpireAt
      // 解析；仅用于启动流程验证，非真实凭据、服务端不认）
      final days = _mode == 'near' ? 10 : 30;
      final expireSec = DateTime.now()
          .add(Duration(days: days))
          .millisecondsSinceEpoch ~/
          1000;
      final sess = '12345,$expireSec,${'a' * 32}';
      await storage.write(key: sessKey, value: sess);
      if (_mode == 'near') {
        await storage.write(key: jctKey, value: 'seed_jct_fake');
        await storage.write(key: rtKey, value: 'seed_refresh_token_fake');
        debugPrint('[seed] SEED_MODE=near 注入 $days 天后过期会话'
            ' + jct + refresh_token（假凭据，续期将回 -101）');
      } else {
        await storage.delete(key: jctKey);
        await storage.delete(key: rtKey);
        debugPrint('[seed] SEED_MODE=long 注入 $days 天后过期会话（无 token）');
      }
    }
    // 留 2s 让宿主 uiautomator dump / 观察日志稳定
    await tester.pump(const Duration(seconds: 2));
  });
}
