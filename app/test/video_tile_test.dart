// VideoTile 副信息行测试：时长 · UP主（· 发布时间）。
// - 新数据（pubdate 非空）→ 副信息行含 `· yyyy-MM-dd`
// - 旧数据（pubdate null / 0）→ 副信息行与旧版逐字符一致（不含日期段），
//   不崩、不破坏布局（标题/时长照常渲染）
// 纯 widget 测试，无网络（cover 空串 → CoverImage 走本地占位）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/widgets/video_tile.dart';

/// 与模型 formatPubdate 同语义的本地日期推导（跨时区机器测试稳定）。
String _dateText(int sec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

WhitelistVideo _video({int? pubdate}) => WhitelistVideo(
      bvid: 'BV1',
      cid: 1,
      title: '测试视频标题',
      cover: '',
      duration: 90, // 1:30
      upName: 'UP主',
      addedAt: '2026-01-01T00:00:00Z',
      pubdate: pubdate,
    );

Widget _wrap(Widget tile) => MaterialApp(
      home: Scaffold(
        body: ListView(children: [tile]),
      ),
    );

void main() {
  testWidgets('pubdate 非空 → 副信息行 = 时长 · UP主 · yyyy-MM-dd', (tester) async {
    final pubdate = 1682899200; // 2023-05-01T00:00:00Z
    await tester.pumpWidget(_wrap(VideoTile(video: _video(pubdate: pubdate))));
    expect(
      find.text('1:30 · UP主 · ${_dateText(pubdate)}'),
      findsOneWidget,
    );
  });

  testWidgets('pubdate null（旧数据）→ 副信息行 = 时长 · UP主，无日期段', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video())));
    expect(find.text('1:30 · UP主'), findsOneWidget);
    expect(find.textContaining(RegExp(r'· \d{4}-\d{2}-\d{2}')), findsNothing);
    // 标题照常渲染（旧数据不破坏布局）
    expect(find.text('测试视频标题'), findsOneWidget);
  });

  testWidgets('pubdate 0（脏值）→ 与 null 同处理，不显示日期', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video(pubdate: 0))));
    expect(find.text('1:30 · UP主'), findsOneWidget);
    expect(find.textContaining(RegExp(r'· \d{4}-\d{2}-\d{2}')), findsNothing);
  });
}
