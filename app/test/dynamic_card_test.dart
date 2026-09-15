// 动态卡（DynamicCard）手势测试（v2.31.0+ 整卡可点；不访问网络）。
//
// 覆盖：
// - 传了 `onTap`：点**正文/留白**触发 `onTap`（整卡进详情页的那条路）
// - 点**配图**仍走 `onImageTap`（并且 `onTap` 不被误触发）
// - 点**视频投稿卡**仍走 `onVideoTap`（同样不误触发 `onTap`）
//   —— 三条互不抢占：图片与视频块各自是更深的手势识别器，Flutter 的手势竞技场
//   里更深者胜，所以整卡 InkWell 只吃它们外面那圈
// - **不传 `onTap`**：整卡不挂手势（回归——点正文什么都不发生，与改动前一致）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/dynamic_item.dart';
import 'package:bili_whitelist_app/widgets/dynamic_card.dart';

DynamicItem _item() => DynamicItem(
      id: '1',
      type: DynamicType.av,
      pubTs: 1700000000,
      authorName: '动态君',
      text: '正文',
      imageUrls: const [
        'https://i0.hdslb.com/1.jpg',
        'https://i0.hdslb.com/2.jpg',
      ],
      videoBvid: 'BV1card1111',
      videoTitle: '视频标题',
      videoCover: '',
    );

/// 测试环境里图床请求一律 400 → 图片加载失败是预期内的（errorBuilder 兜底）；取走。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pump(
  WidgetTester tester,
  DynamicCard card,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: card)),
  ));
  await tester.pump();
  _drainImageErrors(tester);
}

void main() {
  testWidgets('传了 onTap：点正文触发整卡回调；点图片/视频卡各走自己的回调',
      (tester) async {
    var cardTaps = 0;
    List<String>? tappedUrls;
    int? tappedIndex;
    var videoTaps = 0;

    await _pump(
      tester,
      DynamicCard(
        item: _item(),
        onTap: () => cardTaps++,
        onImageTap: (urls, index) {
          tappedUrls = urls;
          tappedIndex = index;
        },
        onVideoTap: () => videoTaps++,
      ),
    );

    // ① 正文 → 整卡
    await tester.tap(find.text('正文'));
    await tester.pump();
    expect(cardTaps, 1);
    expect(tappedIndex, isNull, reason: '不该顺带触发图片回调');
    expect(videoTaps, 0);

    // ② 配图 → 图片回调（整卡回调不被误触发）
    final thumbs = find.descendant(
      of: find.byType(DynamicImages),
      matching: find.byType(GestureDetector),
    );
    expect(thumbs, findsNWidgets(2));
    await tester.tap(thumbs.last, warnIfMissed: false);
    await tester.pump();
    _drainImageErrors(tester);
    expect(tappedUrls, [
      'https://i0.hdslb.com/1.jpg',
      'https://i0.hdslb.com/2.jpg',
    ]);
    expect(tappedIndex, 1, reason: '被点的是第 2 张');
    expect(cardTaps, 1, reason: '点图片不该触发整卡回调');
    expect(videoTaps, 0);

    // ③ 视频投稿卡 → 视频回调（整卡回调不被误触发）
    await tester.tap(find.descendant(
      of: find.byType(DynamicVideo),
      matching: find.byType(InkWell),
    ));
    await tester.pump();
    expect(videoTaps, 1);
    expect(cardTaps, 1, reason: '点视频卡不该触发整卡回调');
    expect(tappedIndex, 1, reason: '图片回调也不该被触发');
  });

  testWidgets('不传 onTap：整卡不挂手势（点正文什么都不发生，与改动前一致）',
      (tester) async {
    var imageTaps = 0;
    var videoTaps = 0;

    await _pump(
      tester,
      DynamicCard(
        item: _item(),
        onImageTap: (_, __) => imageTaps++,
        onVideoTap: () => videoTaps++,
      ),
    );

    // 整卡没有额外的 InkWell：只剩视频投稿卡自己那一个
    expect(find.byType(InkWell), findsOneWidget);

    await tester.tap(find.text('正文'));
    await tester.pump();
    expect(imageTaps, 0);
    expect(videoTaps, 0, reason: '点正文不该触发视频/图片回调');

    // 既有两个回调仍然照常工作（回归）
    await tester.tap(find.descendant(
      of: find.byType(DynamicVideo),
      matching: find.byType(InkWell),
    ));
    await tester.pump();
    expect(videoTaps, 1);
    expect(imageTaps, 0);
  });

  testWidgets('两个回调都不传（老用法）：作者行/正文照常渲染', (tester) async {
    await _pump(tester, DynamicCard(item: _item()));

    expect(find.text('动态君'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing, reason: 'onVideoTap 为 null → 视频块不挂手势');
  });
}
