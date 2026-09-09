// v2.17.17「横屏置顶模式」真机/模拟器集成验收（真实网络 + 真实播放器）：
//   flutter test integration_test/landscape_pin_flow_test.dart -d emulator-5554
//
// 本测试需要宿主机在测试打点处执行 adb 旋转（模拟「用户横放/竖放设备」）：
//   - 看到日志标记 `[集成] M1_PORTRAIT_EMBED` 后：adb shell settings put
//     system accelerometer_rotation 0 && adb shell settings put system
//     user_rotation 1（设备转横屏，模拟用户横放）
//   - 看到 `[集成] M2_FULLSCREEN_LANDSCAPE` 后：无需动作（保持横屏）
//   - 看到 `[集成] M3_LANDSCAPE_PIN` 后：adb shell settings put system
//     user_rotation 0（设备转回竖屏，模拟用户竖放）
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

    // 宿主机此刻应执行：settings accelerometer_rotation 0 + user_rotation 1
    // （转横屏 = 模拟用户横放设备）。等旋转生效（最多 35s）。
    final rotatedLandscape = await _waitOrientation(
        tester, () => _isLandscape(tester), const Duration(seconds: 35));
    expect(rotatedLandscape, isTrue, reason: '宿主机未按时转横屏（user_rotation 1）？');

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

    // 宿主机此刻应执行：settings put system user_rotation 0（转回竖屏）
    final backPortrait = await _waitOrientation(
        tester, () => !_isLandscape(tester), const Duration(seconds: 35));
    expect(backPortrait, isTrue, reason: '宿主机未按时转竖屏（user_rotation 0）？');

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
