import 'package:flutter/material.dart';

import 'schedule_page.dart';

/// 「日程」全屏页（v2.69.0）：原底部导航第 3 项页签的内容，现在由
/// 「个人 → 设置 → 日程」入口 push 出来。
///
/// ## 为什么只包一层
/// [SchedulePage] 是按「PageView 的一页」写的 —— **自身不带 Scaffold**
/// （见它的类注释）。搬成独立路由后必须由外面给 Scaffold + AppBar，
/// 否则没有背景、没有返回按钮，头部还会顶到状态栏里。
///
/// 功能一条都没改：网格编辑、拖动填充、加行加列、导入 xlsx、本地存储
/// 全在 [SchedulePage] 内部，这个包装页不参与任何业务逻辑 —— 也因此
/// 现有 28 条 `schedule_page_test.dart` 只需直接 pump [SchedulePage]，
/// 不用跟着改。
class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // push 进来时 Navigator 自动给返回按钮
      appBar: AppBar(title: const Text('日程')),
      // const：页面重建时 SchedulePage 的 Element 不变，正在拖的态不会被重置
      body: const SchedulePage(),
    );
  }
}
