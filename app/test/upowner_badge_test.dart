// 信息行 UP 主入口 [UpownerBadge] 组件测试（阶段 C 播放页 UP 主入口）：
// - 名字渲染（face 空 → 首字圆形占位 + 名字文本）
// - face 非空：测试环境网络图必然失败 → errorBuilder 兜底占位不崩
// - 点击分发：onTap 回调触发（播放页据此 push UpownerPage(mid)）
// - onTap 为 null：纯展示不可点（点击不触发任何回调）
//
// 纯 widget 测试，无网络（Image.network 在测试环境默认 400 → errorBuilder）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/widgets/upowner_badge.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: child),
      ),
    );

void main() {
  testWidgets('face 空 → 圆形占位（名字首字）+ 名字文本', (tester) async {
    await tester.pumpWidget(_wrap(const UpownerBadge(name: '老番茄')));
    // 占位首字
    expect(find.text('老'), findsOneWidget);
    // 名字全文
    expect(find.text('老番茄'), findsOneWidget);
    // 头像/名字区都在
    expect(find.byKey(const ValueKey('upowner-badge-avatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('upowner-badge-name')), findsOneWidget);
  });

  testWidgets('face 非空：网络图失败 → 兜底占位不崩（errorBuilder 路径）',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const UpownerBadge(name: '老番茄', face: 'http://example.com/face.jpg'),
    ));
    // 等网络错误 settle（测试环境 HttpClient 立即回 400）
    await tester.pumpAndSettle();
    expect(find.text('老番茄'), findsOneWidget);
    // errorBuilder 兜底 → 首字占位仍在
    expect(find.text('老'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击 → onTap 回调触发（分发 mid → 进 UP 主页的入口回调）',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_wrap(
      UpownerBadge(name: '老番茄', onTap: () => tapped++),
    ));
    await tester.tap(find.byKey(const ValueKey('upowner-badge')));
    expect(tapped, 1);
  });

  testWidgets('onTap 为 null（纯展示）→ 点击不触发任何回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_wrap(
      UpownerBadge(
        name: '老番茄',
        onTap: null,
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('upowner-badge')),
        warnIfMissed: false);
    await tester.pump();
    expect(tapped, 0);
    expect(find.text('老番茄'), findsOneWidget);
  });

  testWidgets('名字为空 → 占位显示 ?，不崩', (tester) async {
    await tester.pumpWidget(_wrap(const UpownerBadge(name: '')));
    expect(find.text('?'), findsOneWidget);
  });
}
