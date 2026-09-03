// 弹幕增强（v2.16.6+）单元测试：
// - DanmakuLanes：滚动真碰撞轨道分配（空轨/同速/快慢追尾/打满丢弃/出屏
//   腾空）、顶部/底部行堆叠与全忙丢弃、advance 推进
// - DanmakuSettings：屏蔽词 substring 匹配（大小写不敏感）、类型屏蔽判定、
//   透明度 clamp、JSON 序列化/容错
// - DanmakuSettingsStore：shared_preferences mock 存取 roundtrip、
//   无记录/损坏 JSON → 默认设置
// - DanmakuOverlay：widget smoke（Ticker + 发射 + 透明度设置不抛异常）
// 不访问真实网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/danmaku.dart';
import 'package:bili_whitelist_app/models/danmaku_lanes.dart';
import 'package:bili_whitelist_app/models/danmaku_settings.dart';
import 'package:bili_whitelist_app/services/danmaku_settings_store.dart';
import 'package:bili_whitelist_app/widgets/danmaku_overlay.dart';

/// 构造一条测试弹幕。
Danmaku _dm(String text,
    {double timeSec = 1, int mode = 1, int fontSize = 25, int color = 0xFFFFFFFF}) {
  return Danmaku(
    timeSec: timeSec,
    mode: mode,
    fontSize: fontSize,
    color: color,
    text: text,
  );
}

/// 标准测试分配器：屏宽 400、入场间隙 10（起点 x0=410）、2 滚动轨、
/// 2 顶行、2 底行、停留 3.5s。
DanmakuLanes _lanes({int scroll = 2}) => DanmakuLanes(
      screenWidth: 400,
      entryGap: 10,
      scrollLanes: scroll,
      topLanes: 2,
      bottomLanes: 2,
      staySec: 3.5,
    );

void main() {
  group('DanmakuLanes 滚动轨道真碰撞', () {
    test('空轨直接用（返回下标 0）', () {
      final lanes = _lanes();
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      expect(lanes.busyScrollLanes, 0); // 尚未 mark 不计占用
    });

    test('同速/同宽连发：自动分散到不同轨道，打满丢弃', () {
      final lanes = _lanes(scroll: 2);
      // 第一条进 0 轨：尾缘 = 410 + 100 = 510（还堵在入口右侧）
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 100);
      // 第二条同速同宽：0 轨起步即叠（尾缘 510 > 入口 410）→ 换 1 轨
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 1);
      lanes.markScrollLane(1, textWidth: 100, speed: 100);
      // 第三条同速同宽：两条轨道都刚发过（尾缘都 > 入口）→ 全部拒绝
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), isNull);
      expect(lanes.scrollDropped, 1);
      expect(lanes.busyScrollLanes, 2);
    });

    test('单轨满员时连发丢弃，推进出屏后腾空可用', () {
      final lanes = _lanes(scroll: 1);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 100);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), isNull);
      // 弹幕 510px 尾缘以 100px/s 向左：走 5.2s 已完全出屏 → 腾空
      lanes.advance(5.2);
      expect(lanes.busyScrollLanes, 0);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
    });

    test('前车尾缘已让出入口（同速同宽）→ 同轨可跟，前后保持间距', () {
      final lanes = _lanes(scroll: 1);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 100);
      // 推进 1.1s：尾缘 510 - 110 = 400，恰让出入口（x0=410）→ dx>0
      lanes.advance(1.1);
      // 同速：永不追尾 → 可用（同一条轨道上跟车）
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
    });

    test('快车追慢车：追上时慢车还没出屏 → 拒（否则同轨叠字）', () {
      final lanes = _lanes(scroll: 1);
      // 慢前车：宽 100、50px/s，尾缘 510
      expect(lanes.pickScrollLane(textWidth: 100, speed: 50), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 50);
      // 推进到慢车尾缘 200（510 - 50*6.2）：还需 4s 才出屏
      lanes.advance(6.2);
      // 快后车 200px/s 宽 50：追上时间 1.4s < 前车出屏 4s → 拒
      expect(lanes.pickScrollLane(textWidth: 50, speed: 200), isNull);
      expect(lanes.scrollDropped, 1);
    });

    test('快车追慢车但慢车马上出屏 → 可用（追上时已让出）', () {
      final lanes = _lanes(scroll: 1);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 100);
      // 推进 4.6s：前车尾缘 510 - 460 = 50（0.5s 后出屏）
      lanes.advance(4.6);
      expect(lanes.pickScrollLane(textWidth: 50, speed: 200), 0);
    });

    test('慢车永不追尾快车（前车更快离场）→ 可用', () {
      final lanes = _lanes(scroll: 1);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 200), 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 200);
      lanes.advance(2.0); // 尾缘 510 - 400 = 110（已在入口左侧）
      expect(lanes.pickScrollLane(textWidth: 50, speed: 100), 0);
    });

    test('mark 后立即可见占用，未 mark 不占', () {
      final lanes = _lanes(scroll: 2);
      expect(lanes.pickScrollLane(textWidth: 100, speed: 100), 0);
      expect(lanes.busyScrollLanes, 0);
      lanes.markScrollLane(0, textWidth: 100, speed: 100);
      expect(lanes.busyScrollLanes, 1);
    });
  });

  group('DanmakuLanes 顶部/底部堆叠', () {
    test('顶部：优先最上空行（0=顶行），逐行填满后丢弃并计数', () {
      final lanes = _lanes();
      expect(lanes.pickTopLane(), 0);
      lanes.markTopLane(0);
      expect(lanes.pickTopLane(), 1); // 上行被占 → 次行
      lanes.markTopLane(1);
      expect(lanes.pickTopLane(), isNull); // 全忙 → 丢
      expect(lanes.topDropped, 1);
      // 停留结束后释放，新弹幕可复用最上空行
      lanes.advance(3.5);
      expect(lanes.pickTopLane(), 0);
    });

    test('底部：行堆叠 + 全忙丢弃，advance 释放', () {
      final lanes = _lanes();
      expect(lanes.pickBottomLane(), 0);
      lanes.markBottomLane(0);
      expect(lanes.pickBottomLane(), 1);
      lanes.markBottomLane(1);
      expect(lanes.pickBottomLane(), isNull);
      expect(lanes.bottomDropped, 1);
      lanes.advance(2.0);
      expect(lanes.pickBottomLane(), isNull); // 还没停完
      lanes.advance(1.6);
      expect(lanes.pickBottomLane(), 0);
    });
  });

  group('DanmakuSettings 屏蔽/透明度', () {
    test('normalizeWords：trim + 去空 + 去重保序', () {
      expect(DanmakuSettings.normalizeWords([' a ', '', 'b', ' a ', 'a']),
          ['a', 'b']);
    });

    test('屏蔽词 substring 匹配（大小写不敏感）', () {
      const s = DanmakuSettings(blockWords: ['哈哈哈', 'awsl']);
      expect(s.isTextBlocked('这弹幕哈哈哈真好笑'), isTrue);
      expect(s.isTextBlocked('AWSL'), isTrue); // 英文不区分大小写
      expect(s.isTextBlocked('完全无关内容'), isFalse);
    });

    test('类型屏蔽：滚动/顶部/底部独立开关', () {
      const s = DanmakuSettings(blockTop: true, blockBottom: true);
      expect(s.isTypeBlocked(_dm('滚', mode: 1)), isFalse);
      expect(s.isTypeBlocked(_dm('顶', mode: 5)), isTrue);
      expect(s.isTypeBlocked(_dm('底', mode: 4)), isTrue);
    });

    test('blockReason / shouldBlock：类型优先于关键词', () {
      const s = DanmakuSettings(blockScroll: true, blockWords: ['屏蔽词']);
      expect(s.blockReason(_dm('滚', mode: 1)), DanmakuBlockReason.type);
      expect(s.blockReason(_dm('含屏蔽词内容', mode: 5)),
          DanmakuBlockReason.keyword);
      expect(s.blockReason(_dm('干净', mode: 5)), DanmakuBlockReason.none);
      expect(s.shouldBlock(_dm('干净', mode: 1)), isTrue);
      expect(s.shouldBlock(_dm('干净', mode: 5)), isFalse);
    });

    test('copyWith opacity 超界自动 clamp 到 0.2~1.0', () {
      const s = DanmakuSettings();
      expect(s.copyWith(opacity: 0.05).opacity, kDanmakuOpacityMin);
      expect(s.copyWith(opacity: 1.5).opacity, kDanmakuOpacityMax);
      expect(s.copyWith(opacity: 0.5).opacity, closeTo(0.5, 1e-9));
      // 不改字段 → 保持
      expect(s.copyWith().opacity, 1.0);
    });

    test('JSON roundtrip 保留全部字段', () {
      const s = DanmakuSettings(
        blockWords: ['词1', '词2'],
        blockScroll: true,
        blockBottom: true,
        opacity: 0.5,
      );
      final back = DanmakuSettings.fromJson(s.toJson());
      expect(back.blockWords, s.blockWords);
      expect(back.blockScroll, isTrue);
      expect(back.blockTop, isFalse);
      expect(back.blockBottom, isTrue);
      expect(back.opacity, closeTo(0.5, 1e-9));
    });

    test('fromJson 容错：缺字段/类型非法/脏词 → 回退默认/清洗', () {
      // 完全空 map → 全默认
      final def = DanmakuSettings.fromJson(const {});
      expect(def.blockWords, isEmpty);
      expect(def.opacity, 1.0);
      // 脏类型 → 默认（bool 不是 bool、opacity 超界 clamp）
      final dirty = DanmakuSettings.fromJson(const {
        'blockWords': [' 有空格 ', '', 'ok'],
        'blockScroll': 'not-bool',
        'opacity': 9.0,
      });
      expect(dirty.blockWords, ['有空格', 'ok']); // 清洗生效
      expect(dirty.blockScroll, isFalse);
      expect(dirty.opacity, kDanmakuOpacityMax);
    });
  });

  group('DanmakuSettingsStore', () {
    test('无记录 → 默认设置', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await DanmakuSettingsStore.instance.get();
      expect(s.blockWords, isEmpty);
      expect(s.opacity, 1.0);
      expect(s.blockScroll, isFalse);
    });

    test('save → get roundtrip', () async {
      SharedPreferences.setMockInitialValues({});
      const saved = DanmakuSettings(
        blockWords: ['awsl', '哈哈哈哈'],
        blockTop: true,
        opacity: 0.45,
      );
      await DanmakuSettingsStore.instance.save(saved);
      final back = await DanmakuSettingsStore.instance.get();
      expect(back.blockWords, ['awsl', '哈哈哈哈']);
      expect(back.blockTop, isTrue);
      expect(back.blockScroll, isFalse);
      expect(back.opacity, closeTo(0.45, 1e-9));
    });

    test('存储数据损坏（非法 JSON）→ 默认设置，不抛', () async {
      SharedPreferences.setMockInitialValues(
          {'danmaku:settings': '{{{ 不是 json'});
      final s = await DanmakuSettingsStore.instance.get();
      expect(s.blockWords, isEmpty);
      expect(s.opacity, 1.0);
    });

    test('覆盖保存：后保存覆盖先保存', () async {
      SharedPreferences.setMockInitialValues({});
      await DanmakuSettingsStore.instance
          .save(const DanmakuSettings(blockWords: ['旧词']));
      await DanmakuSettingsStore.instance
          .save(const DanmakuSettings(opacity: 0.6));
      final back = await DanmakuSettingsStore.instance.get();
      expect(back.blockWords, isEmpty); // 被覆盖清空
      expect(back.opacity, closeTo(0.6, 1e-9));
    });
  });

  group('DanmakuOverlay smoke', () {
    testWidgets('Ticker 空转 + 屏蔽 + 透明度设置下发射不抛异常', (tester) async {
      // 混合滚动/顶部/底部 + 部分命中屏蔽词
      final list = [
        _dm('滚动一', timeSec: 0.2),
        _dm('滚动二', timeSec: 0.5),
        _dm('顶部甲', timeSec: 0.6, mode: 5),
        _dm('底部乙', timeSec: 0.8, mode: 4),
        _dm('屏蔽词弹幕', timeSec: 1.0),
      ];
      const settings = DanmakuSettings(
        blockWords: ['屏蔽词'],
        opacity: 0.5,
      );
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 800,
            child: DanmakuOverlay(
              danmaku: list,
              playing: true,
              positionMs: 2000, // 全部 timeSec 已到 → 全部发射/过滤
              settings: settings,
            ),
          ),
        ),
      ));
      // 推进若干帧让 Ticker 跑：layout/发射/推进/绘制路径全部执行
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 2));
      // 卸载（dispose ticker + TextPainter），无异常即通过
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('设置实例变化（copyWith）→ 清屏重载不抛异常', (tester) async {
      final list = [_dm('内容', timeSec: 0.1)];
      Widget build(DanmakuSettings s) => MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 800,
                child: DanmakuOverlay(
                  danmaku: list,
                  playing: true,
                  positionMs: 3000,
                  settings: s,
                ),
              ),
            ),
          );
      await tester.pumpWidget(build(const DanmakuSettings()));
      await tester.pump(const Duration(milliseconds: 100));
      // 换新设置实例（父层 setState 后 overlay didUpdateWidget 走重载分支）
      await tester.pumpWidget(build(const DanmakuSettings(opacity: 0.3)));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
