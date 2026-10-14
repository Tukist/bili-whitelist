// 个人页「取流状态」块（v2.53.0）测试。
//
// 用户原话：「我要怎么确定现在是普通模式还是免流模式」。这一块要一眼给出：
//   1. **三态**：普通模式（网页接口）/ App 形态（实验）/ **App 形态已在本会话回退**
//      —— 回退态必须能显示（回退是静默的、不改用户设置，不显示用户会一直以为
//      还在走 App 形态）；
//   2. **最近一次取流的实测事实**（接口来源 / 清晰度 / 带没带登录 Cookie / 什么时候）；
//   3. **一句如实说明**：免流是否生效只能看运营商侧，这里只表示走了哪条接口。
//
// 文案纪律：设置里的小字用户要求"不超过两行"→ 本文件按"非空白字符 ≤ 42"钉住
// 导出的小字常量（与 `stream_compat_test.dart` 对 kStreamCompatHint 的做法一致）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/stream_status_store.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/stream_status_view.dart';

/// 挂上「取流状态」块（只需要一个 Scaffold 供主题/SnackBar 用）。
Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(body: StreamStatusView()),
  ));
  await tester.pumpAndSettle();
}

/// 当前显示的形态文案（读那一行的 Text）。
String _modeText(WidgetTester tester) =>
    (tester.widget<Text>(find.byKey(kStreamStatusModeKey))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest();
    StreamStatusStore.instance.resetForTest(loaded: true);
  });

  tearDown(() {
    UiPrefsStore.instance.resetForTest();
    StreamStatusStore.instance.resetForTest();
  });

  group('① 三态判定（纯函数，与 config.streamCompatInUse 同判据）', () {
    test('开关关着 → 普通模式（网页接口）', () {
      expect(streamModeLabel(enabled: false, sessionFallback: false),
          kStreamModeWeb);
      expect(kStreamModeWeb, contains('网页接口'));
    });

    test('开关开着且未回退 → App 形态（实验）', () {
      expect(streamModeLabel(enabled: true, sessionFallback: false),
          kStreamModeApp);
    });

    test('开关开着但本会话已回退 → 必须显式说出"已回退"（三态里的第三态）', () {
      expect(streamModeLabel(enabled: true, sessionFallback: true),
          kStreamModeAppFallback);
      expect(kStreamModeAppFallback, contains('回退'));
    });

    test('回退标记是在"开关开着"的前提下才影响形态（开关关着就是普通模式）', () {
      expect(streamModeLabel(enabled: false, sessionFallback: true),
          kStreamModeWeb,
          reason: '开关都没开，谈不上"App 形态已回退"');
    });
  });

  group('② 小字长度与内容契约', () {
    test('如实说明：非空白字符 ≤ 42，且明确"免流只能看运营商侧"', () {
      expect(kStreamModeHonestNote, contains('运营商'));
      expect(kStreamModeHonestNote, contains('免流'));
      // 不许写成"你现在在免流"
      expect(kStreamModeHonestNote.contains('你在免流'), isFalse);
      final n = kStreamModeHonestNote.replaceAll(RegExp(r'\s'), '').length;
      expect(n, lessThanOrEqualTo(42), reason: '用户要求设置页小字两行（当前 $n 字）');
    });
  });

  group('③ 「最近一次取流」那一行', () {
    test('没有记录 → null（界面就不显示这一行）', () {
      expect(
        lastStreamSummary(
            source: null, quality: 0, hadLoginCookie: false, at: null),
        isNull,
      );
      expect(
        lastStreamSummary(
            source: StreamSource.app,
            quality: 32,
            hadLoginCookie: false,
            at: null),
        isNull,
        reason: '来源在但时刻丢了（脏数据）→ 也不显示',
      );
    });

    test('App 形态：接口 + 清晰度名 + 带登录 Cookie + 时间', () {
      final s = lastStreamSummary(
        source: StreamSource.app,
        quality: 32,
        hadLoginCookie: true,
        at: DateTime(2026, 10, 14, 18, 30),
      );
      expect(s, isNotNull);
      expect(s, contains('App 形态'));
      expect(s, contains('480P'), reason: '32 = 480P（playViewQualityName 同一份映射）');
      expect(s, contains('带登录 Cookie'));
      expect(s, contains('10-14 18:30'));
    });

    test('网页接口 + 未知档位 + 未带 Cookie', () {
      final s = lastStreamSummary(
        source: StreamSource.web,
        quality: 0,
        hadLoginCookie: false,
        at: DateTime(2026, 1, 2, 3, 4),
      );
      expect(s, contains('网页接口'));
      expect(s, contains('清晰度未知'), reason: 'quality=0 不许硬说成 360P');
      expect(s, contains('未带登录 Cookie'));
      expect(s, contains('01-02 03:04'), reason: '月/日/时/分都补零');
    });
  });

  group('④ 组件：三态 + 实测信息 + 如实说明', () {
    testWidgets('默认（开关关、没有记录）：显示普通模式 + 如实说明，不显示实测行',
        (tester) async {
      await _pump(tester);
      expect(find.byKey(kStreamStatusKey), findsOneWidget);
      expect(_modeText(tester), kStreamModeWeb);
      expect(find.text(kStreamModeHonestNote), findsOneWidget);
      expect(find.textContaining('最近一次'), findsNothing);
    });

    testWidgets('开关打开 → 切成 App 形态（实验）', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      await _pump(tester);
      expect(_modeText(tester), kStreamModeApp);
    });

    testWidgets('会话内自动回退 → 立刻显示第三态（回退不发通知就会一直骗人）',
        (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      await _pump(tester);
      expect(_modeText(tester), kStreamModeApp, reason: '一开始在走 App 形态');

      // 播放页真的回退时就是这么调的（player_page._autoFallbackStreamCompat）
      UiPrefsStore.instance.markStreamCompatSessionFallback();
      await tester.pump();
      expect(_modeText(tester), kStreamModeAppFallback,
          reason: '回退必须可见：否则用户看着开关是开的，以为还在走 App 形态');
    });

    testWidgets('有记录 → 显示最近一次取流的实测信息', (tester) async {
      await StreamStatusStore.instance.record(
        source: StreamSource.app,
        quality: 32,
        hadLoginCookie: true,
        at: DateTime(2026, 10, 14, 18, 30),
      );
      await _pump(tester);
      expect(find.textContaining('最近一次：App 形态'), findsOneWidget);
      expect(find.textContaining('480P'), findsOneWidget);
      expect(find.textContaining('带登录 Cookie'), findsOneWidget);
      expect(find.text(kStreamModeHonestNote), findsOneWidget);
    });

    testWidgets('冷启动从盘上读回上次结果（重启后仍看得到）', (tester) async {
      SharedPreferences.setMockInitialValues({
        StreamStatusStore.sourceKey: 'web',
        StreamStatusStore.qualityKey: 80,
        StreamStatusStore.cookieKey: true,
        StreamStatusStore.atKey: DateTime(2026, 10, 14, 8, 1)
            .millisecondsSinceEpoch,
      });
      StreamStatusStore.instance.resetForTest(loaded: false); // 模拟重启
      await _pump(tester);
      expect(find.textContaining('最近一次：网页接口'), findsOneWidget);
      expect(find.textContaining('1080P'), findsOneWidget);
    });

    testWidgets('读盘失败（key 全缺）→ 只显示形态与说明，不崩', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      StreamStatusStore.instance.resetForTest();
      await _pump(tester);
      expect(_modeText(tester), kStreamModeApp);
      expect(find.textContaining('最近一次'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
