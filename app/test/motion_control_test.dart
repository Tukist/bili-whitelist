// 装饰性动画总开关（lib/theme/motion_control.dart）单测：
// - 默认值随环境：`flutter test`（FLUTTER_TEST）下关闭，生产下开启
// - 系统「减少动画」（MediaQuery.disableAnimations）时统一入口返回 false
// - 显式置 false 时压过系统设置
// - reset() 恢复默认（测试之间不互相污染）
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/motion_control.dart';

/// 在一棵**只有 MediaQuery**（不套 MaterialApp，免得被 App 自己插入的
/// MediaQuery 覆盖掉）的树里读一次 [MotionControl.of]。
Future<bool> _readOf(WidgetTester tester, {required bool disableAnimations}) async {
  late bool value;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Builder(
        builder: (context) {
          value = MotionControl.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return value;
}

void main() {
  // 任何一条失败也不把开关留在非默认值上（其它测试文件按文件隔离，
  // 但同文件内的用例共用同一个静态字段）
  tearDown(MotionControl.reset);

  test('默认值随环境：flutter test 下关闭，生产（无 FLUTTER_TEST）下开启', () {
    final isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
    // 机制本身：`flutter test` 会给子进程注入 FLUTTER_TEST
    expect(isFlutterTest, isTrue, reason: '本用例就跑在 flutter test 里');
    // → 默认 = !_isFlutterTest = false：无限循环动画不会卡住 pumpAndSettle
    expect(MotionControl.enabled, isFalse);
    // 生产语义（"恒为 true"）由同一个表达式保证：无 FLUTTER_TEST 的进程里
    // 默认值即 true。本进程必然是测试进程，无法直接复现，故锁住等价关系。
    expect(MotionControl.enabled, !isFlutterTest);
  });

  testWidgets('系统未要求减少动画 → of() 为 true（显式开启装饰性动画）', (tester) async {
    MotionControl.enabled = true;
    expect(await _readOf(tester, disableAnimations: false), isTrue);
  });

  testWidgets('系统开启「减少动画」→ of() 为 false', (tester) async {
    MotionControl.enabled = true; // 先显式开，确保是系统设置这一侧压下来的
    expect(await _readOf(tester, disableAnimations: true), isFalse);
  });

  testWidgets('显式关闭压过系统设置（两种系统设置下都为 false）', (tester) async {
    MotionControl.enabled = false;
    expect(await _readOf(tester, disableAnimations: false), isFalse);
    expect(await _readOf(tester, disableAnimations: true), isFalse);
  });

  testWidgets('媒体查询数据变化后重新读取：树重建即生效', (tester) async {
    MotionControl.enabled = true;
    expect(await _readOf(tester, disableAnimations: true), isFalse);
    expect(await _readOf(tester, disableAnimations: false), isTrue);
  });

  testWidgets('reset() 把开关置回默认值（测试环境下即 false）', (tester) async {
    MotionControl.enabled = true;
    expect(await _readOf(tester, disableAnimations: false), isTrue);
    MotionControl.reset();
    expect(MotionControl.enabled, isFalse);
    expect(await _readOf(tester, disableAnimations: false), isFalse);
  });
}
