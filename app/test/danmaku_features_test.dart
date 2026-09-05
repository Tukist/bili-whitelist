// 弹幕增强（v2.16.6+ → v2.16.13+ 显示区域）单元测试：
// - DanmakuLanes：滚动真碰撞轨道分配（空轨/同速/快慢追尾/打满丢弃/出屏
//   腾空）、顶部/底部行堆叠与全忙丢弃、advance 推进
// - DanmakuSettings：屏蔽词 substring 匹配（大小写不敏感）、类型屏蔽判定、
//   透明度 clamp、JSON 序列化/容错、开关 enabled/显示区域 displayAreaPercent
//   字段（roundtrip / 缺失回默认 / 脏值归一化到 10~100 步进 10）
// - DanmakuSettingsStore：shared_preferences mock 存取 roundtrip、
//   无记录/损坏 JSON → 默认设置
// - DanmakuOverlay：widget smoke（Ticker + 发射 + 透明度设置不抛异常）、
//   显示区域轨道换算纯逻辑 danmakuScrollLaneCount（100% / 30% / 极小区域
//   保底 / 超大屏封顶——**滚动轨占满可用带，不再扣顶部/底部固定行**）、
//   顶/底行 y 换算纯逻辑、小显示区域（30%）三类弹幕共存 + y 不越区域
//   的 widget 测试（v2.16.13 显示区域后的布局调整：顶/底与滚动可重叠）
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

    test('默认值：开关关、显示区域 100（旧版全屏带）', () {
      const s = DanmakuSettings();
      expect(s.enabled, isFalse);
      expect(s.displayAreaPercent, kDanmakuDisplayAreaMax);
    });

    test('displayArea 归一化：越界/非步进收敛到 10~100 的 10 倍数', () {
      expect(DanmakuSettings.normalizeDisplayArea(100), 100);
      expect(DanmakuSettings.normalizeDisplayArea(30), 30);
      expect(DanmakuSettings.normalizeDisplayArea(200), 100);
      expect(DanmakuSettings.normalizeDisplayArea(5), kDanmakuDisplayAreaMin);
      expect(DanmakuSettings.normalizeDisplayArea(33), 30); // 就近 10 倍数
      // copyWith 同样收敛（UI 滑杆步进之外不产生非法值）
      expect(
          const DanmakuSettings().copyWith(displayAreaPercent: 33).displayAreaPercent,
          30);
    });

    test('JSON roundtrip 保留全部字段', () {
      const s = DanmakuSettings(
        blockWords: ['词1', '词2'],
        blockScroll: true,
        blockBottom: true,
        enabled: true,
        displayAreaPercent: 30,
        opacity: 0.5,
      );
      final back = DanmakuSettings.fromJson(s.toJson());
      expect(back.blockWords, s.blockWords);
      expect(back.blockScroll, isTrue);
      expect(back.blockTop, isFalse);
      expect(back.blockBottom, isTrue);
      expect(back.enabled, isTrue);
      expect(back.displayAreaPercent, 30);
      expect(back.opacity, closeTo(0.5, 1e-9));
      // JSON 字面量核对（enabled/displayAreaPercent 字段确实写入）
      expect(s.toJson()['enabled'], isTrue);
      expect(s.toJson()['displayAreaPercent'], 30);
    });

    test('fromJson 容错：缺字段/类型非法/脏词 → 回退默认/清洗', () {
      // 完全空 map → 全默认（含旧版本无 enabled/displayAreaPercent 字段）
      final def = DanmakuSettings.fromJson(const {});
      expect(def.blockWords, isEmpty);
      expect(def.opacity, 1.0);
      expect(def.enabled, isFalse);
      expect(def.displayAreaPercent, kDanmakuDisplayAreaMax);
      // 脏类型 → 默认（bool 不是 bool、opacity 超界 clamp、区域非法收敛）
      final dirty = DanmakuSettings.fromJson(const {
        'blockWords': [' 有空格 ', '', 'ok'],
        'blockScroll': 'not-bool',
        'opacity': 9.0,
        'enabled': 'yes',
        'displayAreaPercent': 7,
      });
      expect(dirty.blockWords, ['有空格', 'ok']); // 清洗生效
      expect(dirty.blockScroll, isFalse);
      expect(dirty.opacity, kDanmakuOpacityMax);
      expect(dirty.enabled, isFalse); // 脏 bool → 默认关
      expect(dirty.displayAreaPercent, kDanmakuDisplayAreaMin); // 7 → 10
    });
  });

  group('DanmakuSettingsStore', () {
    test('无记录 → 默认设置', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await DanmakuSettingsStore.instance.get();
      expect(s.blockWords, isEmpty);
      expect(s.opacity, 1.0);
      expect(s.blockScroll, isFalse);
      expect(s.enabled, isFalse);
      expect(s.displayAreaPercent, kDanmakuDisplayAreaMax);
    });

    test('save → get roundtrip', () async {
      SharedPreferences.setMockInitialValues({});
      const saved = DanmakuSettings(
        blockWords: ['awsl', '哈哈哈哈'],
        blockTop: true,
        enabled: true,
        displayAreaPercent: 30,
        opacity: 0.45,
      );
      await DanmakuSettingsStore.instance.save(saved);
      final back = await DanmakuSettingsStore.instance.get();
      expect(back.blockWords, ['awsl', '哈哈哈哈']);
      expect(back.blockTop, isTrue);
      expect(back.blockScroll, isFalse);
      expect(back.enabled, isTrue);
      expect(back.displayAreaPercent, 30);
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

  group('DanmakuOverlay 显示区域轨道换算（v2.16.13；布局调整后滚动占满带）', () {
    const laneH = 27.0; // 常规行高口径（字号 25 → 17px × 1.6 ≈ 27.2，同量纲）

    test('100%：0.7h 带全部切给滚动（不再扣顶 3 底 2）→ 28 条', () {
      // 屏高 1080：可用带高 = 1080 × 0.7 = 756 → floor(756/27) = 28
      expect(danmakuScrollLaneCount(756, laneH), 28);
    });

    test('区域 30%：带高 226.8 → 8 条（改动前 8-3-2=3——不再被顶/底行挤占）', () {
      // 屏高 1080、区域 30%：带高 = 1080 × 0.7 × 0.3 = 226.8 → floor = 8
      expect(danmakuScrollLaneCount(226.8, laneH), 8);
      // 区域 50%：378 → 14 条
      expect(danmakuScrollLaneCount(378, laneH), 14);
    });

    test('区域小到带高不足一行：保底 1 条滚动轨（不崩溃）', () {
      // 区域 10% 屏高 1080：带高 75.6 → floor(75.6/27) = 2 条
      expect(danmakuScrollLaneCount(75.6, laneH), 2);
      // 带高 < 行高（极小屏 + 10%）：floor = 0 → 保底 1 条
      expect(danmakuScrollLaneCount(20, laneH), 1);
    });

    test('超大屏封顶 60 条滚动轨', () {
      expect(danmakuScrollLaneCount(4000, laneH), 60);
      // 正常小屏行高略变也不影响换算（如 640 高：0.7×640=448 → floor 16 条）
      expect(danmakuScrollLaneCount(448, laneH), 16);
    });
  });

  group('顶/底行 y 换算（重叠语义，纯逻辑）', () {
    const laneH = 27.0;

    test('顶部行 i：y = 顶锚 + i×行高（行 0 显示在显示区域最顶）', () {
      // 30% 屏高 1080 的顶锚 = 0.12×1080×0.3 = 38.88 → 逐行 38.9 / 65.9 / 92.9
      expect(danmakuTopTextY(38.9, 0, laneH), closeTo(38.9, 1e-9));
      expect(danmakuTopTextY(38.9, 1, laneH), closeTo(65.9, 1e-9));
      expect(danmakuTopTextY(38.9, 2, laneH), closeTo(92.9, 1e-9));
    });

    test('顶部行与滚动轨道同 y（共用顶锚）——纵坐标可重叠的基础', () {
      // 顶行 i 与滚动轨 i 都由「顶锚 + i×行高」定位 → 顶/底不再避让滚动
      expect(danmakuTopTextY(38.9, 0, laneH), danmakuTopTextY(38.9, 0, laneH));
      // 顶行 0 即滚动轨 0 的带顶：小区域下顶部弹幕仍在最顶可见
      expect(danmakuTopTextY(38.9, 0, laneH), closeTo(38.9, 1e-9));
    });

    test('底部行 i：y = 底缘 − i×行高 − 文本高（行 0 底边贴底缘，向上堆叠）', () {
      const textH = 23.0;
      // 行 0：文本顶 = 底缘 − 文本高 → 文本底边恰好 = 底缘
      expect(danmakuBottomTextY(265.7, 0, laneH, textH), closeTo(242.7, 1e-9));
      expect(danmakuBottomTextY(265.7, 0, laneH, textH) + textH,
          closeTo(265.7, 1e-9));
      // 行 1：再上移一行高 → 底行之间互不叠（差 = 行高）
      expect(danmakuBottomTextY(265.7, 1, laneH, textH), closeTo(215.7, 1e-9));
      // 与滚动轨可重叠：行 1 顶部（215.7）落在滚动轨带内（如 38.9~265.7）
      expect(danmakuBottomTextY(265.7, 1, laneH, textH),
          greaterThan(danmakuTopTextY(38.9, 0, laneH)));
    });

    test('底部行不越显示区域：行 0 底边 = 底缘，而底缘 ≤ 区域下界', () {
      // 底缘在 _ensureLayout 被钳制 ≤ 屏高×区域比（此处 30% → 240），
      // 行 0 底边 = 底缘 → 任何底行文本底边都不会越出区域下界
      const bottomEdge = 185.6; // min(0.82×240, 240 − 2×27) = 185.6
      expect(danmakuBottomTextY(bottomEdge, 0, laneH, 23.0) + 23.0,
          closeTo(bottomEdge, 1e-9));
      expect(bottomEdge, lessThanOrEqualTo(240.0));
    });
  });

  group('DanmakuOverlay 滚动连续性推进逻辑（v2.16.11）', () {
    test('danmakuSmoothDt：大间隙归零重置 / 普通掉帧钳制 / 正常帧原样', () {
      // 长时间无帧（切后台/引擎停摆恢复，>100ms）→ 0：重置基准、本帧不推进
      expect(danmakuSmoothDt(0.5), 0);
      expect(danmakuSmoothDt(0.101), 0);
      // 普通掉帧（<=100ms）→ 钳制到单帧位移上限（平滑恢复，不大步跳）
      expect(danmakuSmoothDt(0.1), closeTo(kMaxDanmakuDtSec, 1e-9));
      expect(danmakuSmoothDt(0.066), closeTo(kMaxDanmakuDtSec, 1e-9));
      // 正常帧 → 原样返回（按真实流逝推进，无累积漂移）
      expect(danmakuSmoothDt(0.016), closeTo(0.016, 1e-9));
      expect(danmakuSmoothDt(0.0), 0);
    });

    test('danmakuCreditAfter：按真实时间累计并封顶；大间隙帧（dt=0）不涨', () {
      // 满额状态下小帧流逝：不超 cap
      expect(danmakuCreditAfter(kDanmakuSpawnCreditMax, 0.016),
          kDanmakuSpawnCreditMax);
      // 从 0 累计：速率 40 条/s × 0.25s = +10 条 → 封顶 4
      expect(danmakuCreditAfter(0, 0.25), kDanmakuSpawnCreditMax);
      // 大间隙恢复帧 dt=0：信用不涨（积压不会一次性补发）
      expect(danmakuCreditAfter(0, 0.0), 0);
      // 60fps 单帧流逝 +0.64 → 速率 40/s 可持续（平均每帧可发 ~0.6 条）
      expect(danmakuCreditAfter(0, 0.016), closeTo(0.64, 1e-9));
    });

    testWidgets('播放中每帧持续推进；大间隙帧（切后台恢复）重置基准不跳变', (tester) async {
      final list = [_dm('连续滚动', timeSec: 0)];
      Widget build() => MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 800,
                child: DanmakuOverlay(
                  danmaku: list,
                  playing: true,
                  positionMs: 0,
                  settings: const DanmakuSettings(),
                ),
              ),
            ),
          );
      await tester.pumpWidget(build());
      await tester.pump(const Duration(milliseconds: 16)); // 布局完成 → 发射
      await tester.pump(const Duration(milliseconds: 16)); // 移动 1 帧
      final dynamic st = tester.state(find.byType(DanmakuOverlay));
      double prev = st.debugActiveScrollX as double;
      expect(prev, lessThan(410)); // 已从屏外入口（x=410）向左进入
      // 逐小帧推进：**每一帧都在动**（修复前无发射的帧画面静止）
      const stepMs = 16;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: stepMs));
        final x = st.debugActiveScrollX as double;
        expect(x, lessThan(prev));
        expect(prev - x, lessThan(5)); // 单帧位移小且均匀（平滑，非跳跃）
        prev = x;
      }
      // 模拟切后台/引擎停摆恢复：单帧 0.5s 大间隙 → 重置基准，本帧不推进
      await tester.pump(const Duration(milliseconds: 500));
      final afterGap = st.debugActiveScrollX as double;
      expect(afterGap, closeTo(prev, 1e-6)); // 位置不跳（原地继续）
      // 恢复正常小帧 → 继续平滑推进（小步，而非大步"跳进"）
      await tester.pump(const Duration(milliseconds: stepMs));
      final resumed = st.debugActiveScrollX as double;
      expect(resumed, lessThan(afterGap));
      expect(afterGap - resumed, lessThan(5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('暂停冻结不动；恢复后从原位置继续小步推进（基准不跳）', (tester) async {
      final list = [_dm('暂停测试', timeSec: 0)];
      Widget build(bool playing) => MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 800,
                child: DanmakuOverlay(
                  danmaku: list,
                  playing: playing,
                  positionMs: 0,
                  settings: const DanmakuSettings(),
                ),
              ),
            ),
          );
      await tester.pumpWidget(build(true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final dynamic st = tester.state(find.byType(DanmakuOverlay));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final before = st.debugActiveScrollX as double;
      // 暂停：tick 继续跑但冻结（不推进、不重绘）
      await tester.pumpWidget(build(false));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(st.debugActiveScrollX as double, closeTo(before, 1e-6));
      // 恢复：暂停期间基准每帧更新 → 首帧即小步继续，无跳变
      await tester.pumpWidget(build(true));
      await tester.pump(const Duration(milliseconds: 16));
      final after = st.debugActiveScrollX as double;
      expect(after, lessThan(before));
      expect(before - after, lessThan(5));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('DanmakuOverlay 顶/底与滚动重叠（v2.16.13 后布局调整）', () {
    // 屏 400x800、区域 30%：区域下界 = 240px；可用带高 = 800×0.7×0.3 = 168
    // → 行高 27.2 → floor(168/27.2) = **6 条滚动轨**（改动前 6−3−2 = 1 条，
    // 弹幕量被顶/底固定行挤到几乎不可用——本次修复的目标场景）。
    final list = <Danmaku>[
      for (var i = 0; i < 6; i++) _dm('滚$i', timeSec: 0.1 + i * 0.1),
      _dm('顶甲', timeSec: 1.0, mode: 5),
      _dm('顶乙', timeSec: 1.1, mode: 5),
      _dm('底甲', timeSec: 1.2, mode: 4),
      _dm('底乙', timeSec: 1.3, mode: 4),
    ];
    const settings = DanmakuSettings(displayAreaPercent: 30);

    Widget build() => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: DanmakuOverlay(
                danmaku: list,
                playing: true,
                positionMs: 2000, // 全部 timeSec 已到 → 逐帧全部发射
                settings: settings,
              ),
            ),
          ),
        );

    // 测试面固定 400x800（默认 800x600 会把 SizedBox 高度压到 600 → 带高不足，
    // 轨道数就不是本组要断言的 6 条）。
    void setSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('区域 30%：滚动 6 轨占满可用带，顶部 2 + 底部 2 仍全部发射'
        '（不再因滚动/顶/底互斥而被挤掉）', (tester) async {
      setSurface(tester);
      await tester.pumpWidget(build());
      // 推进 ~1.4s：layout + 逐帧发射（发射信用速率 40 条/s：首帧满额 4 条
      // 后按 16ms/帧涓流补发 → 10 条约 0.3s 内全部进入；~1.5s 内滚动未出
      // 屏（穿越 4s）、顶/底未到停留 3.5s 上限 → 全部在屏存活）
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final dynamic st = tester.state(find.byType(DanmakuOverlay));
      // 布局层面：滚动轨占满可用带（6 条），顶部/底部行保留（3/2）
      expect(st.debugLayoutScrollLanes as int, 6);
      // 三类共存：6 滚动 + 2 顶部 + 2 底部全部发射（互不挤占）
      expect((st.debugActiveScrollYs as List).length, 6);
      expect((st.debugActiveTopYs as List).length, 2);
      expect((st.debugActiveBottomYs as List).length, 2);
      // 无任何类型因轨道占用被丢弃（顶/底不再为滚动避让而让行）
      expect(st.debugScrollDropped as int, 0);
      expect(st.debugTopDropped as int, 0);
      expect(st.debugBottomDropped as int, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('区域 30%：滚动轨各自不叠、顶部贴顶锚、底行距 = 行高、'
        '所有 y 不越显示区域', (tester) async {
      setSurface(tester);
      await tester.pumpWidget(build());
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final dynamic st = tester.state(find.byType(DanmakuOverlay));
      final laneH = st.debugLayoutLaneH as double;
      final scrollYs = (st.debugActiveScrollYs as List).cast<double>();
      final topYs = (st.debugActiveTopYs as List).cast<double>()..sort();
      final bottomYs = (st.debugActiveBottomYs as List).cast<double>()..sort();
      // 滚动轨道内部不叠：同时活跃的 6 条各占一行（y 两两不同）
      expect(scrollYs.toSet().length, scrollYs.length);
      // 顶部弹幕：行 0 贴顶锚（显示区域最顶），行 1 距行 0 = 行高（内部堆叠）
      expect(topYs.first, closeTo(st.debugLayoutTopAnchorY as double, 1e-6));
      expect(topYs[1] - topYs[0], closeTo(laneH, 1e-6));
      // 底部弹幕：行 0/1 由底缘向上堆叠，行距 = 行高（底行之间互不叠）
      expect(bottomYs[1] - bottomYs[0], closeTo(laneH, 1e-6));
      // y 不越显示区域（30% → 0 ~ 240px）——顶/底不再向下/上越界
      final regionBottom = 800.0 * 0.3;
      expect(st.debugLayoutBottomEdgeY as double,
          lessThanOrEqualTo(regionBottom));
      for (final y in [...scrollYs, ...topYs, ...bottomYs]) {
        expect(y, greaterThanOrEqualTo(0));
        expect(y, lessThanOrEqualTo(regionBottom));
      }
      await tester.pumpWidget(const SizedBox());
    });
  });
}
