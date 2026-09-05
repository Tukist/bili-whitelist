// flutter drive 用的标准 driver（配合 integration_test 目标文件）：
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/seed_session_test.dart -d emulator-5554 \
//     --dart-define=SEED_MODE=long --keep-app-running
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver();
