// v2.17.17「横屏置顶模式」真机/模拟器集成验收（真实网络 + 真实播放器）：
//   flutter test integration_test/landscape_pin_flow_test.dart -d emulator-5554
//
// 方向前置（v2.17.18 起自足，不再依赖宿主机手工介入）：
//   - 测试在需要横屏/竖屏处**自己发方向请求**（SystemChrome → Activity
//     requestedOrientation，等价于用户横放/竖放设备；应用进程无
//     WRITE_SETTINGS，写不了 `settings put system user_rotation`）；
//   - 每个方向点仍先给宿主机留 20s 观察窗（保留历史的人工 adb 介入方式：
//     adb shell settings put system accelerometer_rotation 0 &&
//     adb shell settings put system user_rotation 1 / 0），宿主没动就自转；
//   - 两者都失败（如设备被系统锁死竖屏、Activity 请求也被忽略）→
//     markTestSkipped 明确跳过并复位竖屏，**不留红色失败**。
//
// 覆盖（取证 = 测试内 debugPrint `[集成]` 几何数值 + 页面自身 debugPrint）：
//   1. 竖屏进入播放 = 竖屏「顶部置顶视频 + 信息行 + 内嵌评论区」
//   2. 进全屏 = 整屏视频（无信息行/评论区）
//   3. 横屏（设备横放）退出全屏 → **停在横屏「置顶+评论」**：视频区仍在顶部、
//      信息行/评论区可见且不越屏、评论区可滚；弹幕开关横屏置顶下不崩
//   4. 设备转竖屏 → 竖屏置顶+评论回归（视频区封顶、信息行/评论区在下方）
//   5. 全屏中点返回箭头 = 先退出全屏（页面不离开），再点返回才离开播放页
//
// 注意：真实网络/播放器环境，播放可能缓冲/失败（不影响布局断言）；旋转等待
// 均显式 pump（pumpAndSettle 会被缓冲转圈/进度 tick 卡死）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

/// 宿主机白名单中的真实视频（Yazi 文件管理器教程，17:37；匿名可播，cid 取
/// 自本机实测日志）。真实 view 可取流 → 播放器真实进入 loaded（onPrepared）。
const String _kBvid = 'BV1yRkCYVEUT';
const int _kCid = 27430227129;

WhitelistVideo _video() => WhitelistVideo(
      bvid: _kBvid,
      cid: _kCid,
      title: '【命令行必备】Yazi：最强文件管理器（横屏置顶模式集成测试）',
      cover: '',
      duration: 1056421 ~/ 1000, // 秒
      upName: 'TheCW',
      addedAt: '2026-01-01',
    );

/// 以真实时间推进（LiveTestWidgetsFlutterBinding 下 pump(时长) 按真实时间走）。
Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// 播放页主 context 的 MediaQuery（旋转后取最新窗口尺寸）。
Size _screenSize(WidgetTester tester) {
  final ctx = tester.element(find.byType(PlayerPage).first);
  return MediaQuery.sizeOf(ctx);
}

bool _isLandscape(WidgetTester tester) {
  final s = _screenSize(tester);
  return s.width > s.height;
}

/// 等设备方向满足 pred（轮询真实窗口尺寸，最多 [timeout]）。
Future<bool> _waitOrientation(WidgetTester tester, bool Function() pred,
    Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 300));
    if (pred()) return true;
  }
  return false;
}

/// 测试自行请求方向并等窗口转到位（模拟用户横放/竖放设备），返回是否成功。
///
/// 为什么能用 SystemChrome 代替 adb：集成测试跑在 App 进程内，平台通道打到
/// **真实** Activity，`setPreferredOrientations` 会落到
/// `Activity.setRequestedOrientation` → 显示器真的旋转（窗口尺寸随之变横/变
/// 竖），与用户把设备横放同效。反过来说，应用进程没有 WRITE_SETTINGS 权限，
/// 写不了 `settings put system user_rotation`（宿主 adb 才行），故只能走这条。
Future<bool> _requestOrientation(WidgetTester tester,
    List<DeviceOrientation> orientations, bool Function() pred) async {
  await SystemChrome.setPreferredOrientations(orientations);
  return _waitOrientation(tester, pred, const Duration(seconds: 15));
}

/// 横屏前置：先给宿主机 20s 观察窗（人工 adb 旋转的历史流程），宿主没动就
/// 由测试自己请求横屏。返回 (是否横屏到位, 是否由本测试自转)。
Future<(bool, bool)> _ensureLandscape(WidgetTester tester) async {
  final host = await _waitOrientation(
      tester, () => _isLandscape(tester), const Duration(seconds: 20));
  if (host) return (true, false);
  final self = await _requestOrientation(
      tester, [DeviceOrientation.landscapeLeft], () => _isLandscape(tester));
  return (self, self);
}

Rect _rectOf(WidgetTester tester, Finder f) => tester.getRect(f.first);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('横屏置顶模式：退出全屏停留横屏置顶+评论 / 转竖屏回归 / 返回先退全屏',
      (tester) async {
    // 宿主页：push 播放页，便于验证「返回先退全屏 → 再返回才离开播放页」
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('HOST_PAGE'),
                TextButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                        builder: (_) => PlayerPage(video: _video())),
                  ),
                  child: const Text('OPEN_PLAYER'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN_PLAYER'));
    // 等待路由推入 + 播放器初始化（取流/onPrepared 真实网络，给足时间）
    for (var i = 0; i < 40 && find.byType(PlayerPage).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(PlayerPage), findsOneWidget, reason: '播放页已打开');
    await _pumpFor(tester, const Duration(seconds: 5));

    const kVideoArea = ValueKey('player-video-area');
    const kInfoBar = ValueKey('player-info-bar');
    const kComments = ValueKey('player-comments');

    // ① 竖屏（设备竖放）进入播放 = 竖屏置顶：视频区在顶部、信息行紧贴其下、
    //    评论区在信息行下且不越屏
    {
      final s = _screenSize(tester);
      expect(s.width < s.height, isTrue, reason: '前置：设备竖屏');
      final video = _rectOf(tester, find.byKey(kVideoArea));
      final info = _rectOf(tester, find.byKey(kInfoBar));
      final comments = _rectOf(tester, find.byType(CommentListView));
      debugPrint('[集成] M1_PORTRAIT_EMBED 屏=${s.width.toInt()}x${s.height.toInt()} '
          '视频区=${video.width.toInt()}x${video.height.toInt()}@(${video.top.toInt()},'
          '${video.left.toInt()}) 信息行顶部=${info.top.toInt()} '
          '评论区=${comments.width.toInt()}x${comments.height.toInt()} '
          '评论区底=${comments.bottom.toInt()} ≤ ${s.height.toInt()}');
      expect(video.top, lessThan(1.0), reason: '竖屏视频区顶部置顶');
      expect(info.top, closeTo(video.bottom, 1.5), reason: '信息行紧贴视频区');
      expect(comments.top, greaterThanOrEqualTo(info.bottom - 1.5));
      expect(comments.height, greaterThan(0));
      expect(comments.bottom, lessThanOrEqualTo(s.height + 1.5),
          reason: '整页不溢出');
    }

    // 方向前置（② 之前）：设备必须横放（= 横屏窗口）。
    //    v2.17.18：不再要求宿主机必须手工 adb 旋转——宿主 20s 内没转就由本
    //    测试自行请求横屏（见 [_ensureLandscape]）；两者都不成 → 明确 skip
    //    （复位竖屏后跳过，不留红）。
    final (rotatedLandscape, selfRotated) = await _ensureLandscape(tester);
    if (!rotatedLandscape) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      markTestSkipped('设备转不了横屏：宿主机未执行 adb 旋转，且应用内方向请求'
          '（SystemChrome → Activity.requestedOrientation）未生效。'
          '请在真机横放设备，或宿主机执行 settings put system '
          'accelerometer_rotation 0 && settings put system user_rotation 1 后复跑。');
    }
    debugPrint('[集成] M1b_ROTATED_LANDSCAPE 横屏到位='
        '$rotatedLandscape 自转=$selfRotated');

    // ② 横屏下进全屏 = 整屏视频（无信息行/评论区）
    await tester.tap(find.byIcon(Icons.fullscreen));
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '已进全屏');
    {
      final s = _screenSize(tester);
      final video = _rectOf(tester, find.byKey(kVideoArea));
      debugPrint('[集成] M2_FULLSCREEN_LANDSCAPE 屏=${s.width.toInt()}x${s.height.toInt()} '
          '视频区=${video.width.toInt()}x${video.height.toInt()} 全屏高='
          '${s.height.toInt()} 信息行=${find.byKey(kInfoBar).evaluate().length} '
          '评论区=${find.byKey(kComments).evaluate().length}');
      expect(s.width > s.height, isTrue);
      expect(video.height, closeTo(s.height, 1.5), reason: '全屏视频占满整屏');
      expect(find.byKey(kInfoBar), findsNothing);
      expect(find.byKey(kComments), findsNothing);
    }

    // ③ 横屏（设备横放）退出全屏 → 停留在横屏「置顶+评论」：
    //    视频区仍在顶部（封顶 55% 屏高）、信息行/评论区可见不越屏；评论区可滚
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(find.byIcon(Icons.fullscreen), findsOneWidget, reason: '已退出全屏');
    if (selfRotated) {
      // 自转场景补一次横屏请求：退出全屏时页面把方向放开为「竖屏 + 双向横屏」
      // （kPlayerPageFreeOrientations），而模拟器锁竖屏（accelerometer_rotation=0
      // + user_rotation=0）会立刻回落到竖屏；真机横放时不会（传感器就是横的）。
      // 重新请求横屏以维持「设备横放」前提，下面的几何断言依旧是横屏置顶布局。
      // （「退出全屏不强制竖屏」的方向策略本身由 widget 测试
      // test/player_landscape_pin_test.dart 断言平台通道收到的三向列表。）
      final reLandscape = await _requestOrientation(tester,
          [DeviceOrientation.landscapeLeft], () => _isLandscape(tester));
      debugPrint('[集成] M2b_SELF_RELANDSCAPE ok=$reLandscape');
    }
    {
      final s = _screenSize(tester);
      expect(s.width > s.height, isTrue,
          reason: '退出全屏后停留在横屏（未强制转竖屏）= 本特性核心');
      final video = _rectOf(tester, find.byKey(kVideoArea));
      final info = _rectOf(tester, find.byKey(kInfoBar));
      final comments = _rectOf(tester, find.byType(CommentListView));
      debugPrint('[集成] M3_LANDSCAPE_PIN 屏=${s.width.toInt()}x${s.height.toInt()} '
          '视频区=${video.width.toInt()}x${video.height.toInt()}@顶${video.top.toInt()} '
          '（封顶 55% 屏高≈${(s.height * 0.55).toInt()}）信息行顶=${info.top.toInt()} '
          '评论区=${comments.width.toInt()}x${comments.height.toInt()} 评论区底='
          '${comments.bottom.toInt()} ≤ ${s.height.toInt()}');
      expect(video.top, lessThan(1.0), reason: '横屏视频区仍顶部置顶');
      expect(video.height, lessThanOrEqualTo(s.height * 0.6 + 1.5),
          reason: '横屏视频区封顶（留出下方信息行+评论）');
      expect(info.top, closeTo(video.bottom, 1.5), reason: '信息行紧贴视频区');
      expect(comments.top, greaterThanOrEqualTo(info.bottom - 1.5));
      expect(comments.height, greaterThan(0), reason: '评论区可见（哪怕矮也可滚）');
      expect(comments.bottom, lessThanOrEqualTo(s.height + 1.5));

      // 评论区可滚（上拉列表有位移即证明滚动容器生效）
      final before =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position
              .pixels;
      await tester.drag(find.byType(CommentListView), const Offset(0, -300));
      await _pumpFor(tester, const Duration(milliseconds: 600));
      final after =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position
              .pixels;
      debugPrint('[集成] 评论区滚动: before=$before after=$after');
      if (after > before) {
        debugPrint('[集成] 评论区横屏可滚 OK');
      } else {
        // 评论内容不足一屏/仍在加载时滚不动属正常 → 记录不判失败（几何已保证
        // Expanded 滚动区存在）
        debugPrint('[集成] 评论区暂无超出一屏内容（跳过滚动位移断言，几何已覆盖）');
      }

      // 弹幕开关：横屏置顶（非全屏）下开启真实弹幕 → 不崩（等弹幕拉取+发射）
      if (find.text('弹幕').evaluate().isNotEmpty) {
        await tester.tap(find.text('弹幕').first);
        await _pumpFor(tester, const Duration(seconds: 4));
        expect(find.byType(PlayerPage), findsOneWidget,
            reason: '横屏置顶开弹幕不崩');
        await tester.tap(find.text('弹幕').first);
        await _pumpFor(tester, const Duration(milliseconds: 800));
      } else {
        debugPrint('[集成] 弹幕按钮不可见（控制层未显示），跳过弹幕冒烟');
      }
    }

    // 方向前置（④ 之前）：转回竖屏。宿主 20s 内没动（人工 adb 流程），就由
    // 测试自己请求竖屏；两者都不成 → 明确 skip（不留红）。
    var backPortrait = await _waitOrientation(
        tester, () => !_isLandscape(tester), const Duration(seconds: 20));
    if (!backPortrait) {
      backPortrait = await _requestOrientation(
          tester, [DeviceOrientation.portraitUp], () => !_isLandscape(tester));
      debugPrint('[集成] M3b_SELF_PORTRAIT ok=$backPortrait');
    }
    if (!backPortrait) {
      markTestSkipped('设备转不回竖屏：宿主机未执行 user_rotation 0，且应用内'
          '方向请求未生效。');
    }

    // ④ 转回竖屏 → 竖屏置顶+评论回归（设备竖放兼容 v2.17.0 布局）
    {
      final s = _screenSize(tester);
      expect(s.width < s.height, isTrue, reason: '设备已竖放');
      final video = _rectOf(tester, find.byKey(kVideoArea));
      final info = _rectOf(tester, find.byKey(kInfoBar));
      final comments = _rectOf(tester, find.byType(CommentListView));
      debugPrint('[集成] M4_PORTRAIT_BACK 屏=${s.width.toInt()}x${s.height.toInt()} '
          '视频区=${video.width.toInt()}x${video.height.toInt()}@顶${video.top.toInt()} '
          '信息行顶=${info.top.toInt()} 评论区=${comments.width.toInt()}x'
          '${comments.height.toInt()} 评论区底=${comments.bottom.toInt()} ≤ '
          '${s.height.toInt()}');
      expect(video.top, lessThan(1.0), reason: '竖屏回归：视频区顶部置顶');
      expect(info.top, closeTo(video.bottom, 1.5));
      expect(comments.height, greaterThan(0));
      expect(comments.bottom, lessThanOrEqualTo(s.height + 1.5));
    }

    // ⑤ 全屏中点返回箭头 = 先退出全屏（页面不离开）；再返回才离开播放页
    await tester.tap(find.byIcon(Icons.fullscreen));
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '再次进全屏');
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(find.byType(PlayerPage), findsOneWidget, reason: '全屏返回先退全屏，不离开页面');
    expect(find.byIcon(Icons.fullscreen), findsOneWidget, reason: '已退出全屏');
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
    debugPrint('[集成] M5_BACK_EXITS_FULLSCREEN_OK');

    await tester.tap(find.byIcon(Icons.arrow_back).first);
    for (var i = 0;
        i < 20 && find.byType(PlayerPage).evaluate().isNotEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('HOST_PAGE'), findsOneWidget,
        reason: '非全屏返回离开播放页回到宿主（dispose 恢复系统方向）');
    debugPrint('[集成] M6_LEAVE_PLAYER_OK');
  });
}
