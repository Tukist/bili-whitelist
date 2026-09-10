/// 入场与动效的"结构参数"（时长/步进/位移量）。
/// 与 app_tokens.dart 的分工：那边是"交互反馈节奏"（按下、切换），
/// 这边是"内容入场节奏"（交错步进、飞行位移），混用会污染交互手感。
///
/// 为什么单独一个文件：`app_tokens.dart` 是 P1 视觉地基（已冻结），
/// 交互节奏被大量既有 widget 直接依赖；入场节奏属于「块化与动效系统」
/// 新引入的一层，改一个数字只影响入场观感，不该动到地基。
library;

import 'package:flutter/animation.dart';

// ==================== 曲线 ====================

/// 烟缕上升：起步快、中途慢、末端几乎停滞（浮力推起后被空气拖住）
const kCurveSmokeRise = Cubic(0.25, 0.10, 0.60, 1.00);

// ==================== 列表项入场（首屏） ====================

/// 单条入场时长
const kDurEntrance = Duration(milliseconds: 240);

/// 相邻条目起步间隔
const kStaggerStep = Duration(milliseconds: 36);

/// 延迟封顶序号（第 N 条之后不再叠加步进，避免长列表尾部等太久）
const kStaggerMaxIndex = 8;

/// 从下方 12px 上移到位
const kEntranceRisePx = 12.0;

// ==================== 列表项入场（翻页追加） ====================

/// 追加条目比首屏更快更密：用户已经在看内容，不需要再"演一遍"
const kDurEntranceAppend = Duration(milliseconds: 180);
const kStaggerStepAppend = Duration(milliseconds: 20);
const kStaggerMaxIndexAppend = 6;

// ==================== 播放页信息块补场（封面 Hero 落地后） ====================

/// 等信息块"补上场"：Hero 先落地，文字块再跟上，避免两套动画抢焦点
const kInfoBlockDelay = Duration(milliseconds: 120);
const kInfoBlockDur = Duration(milliseconds: 320);

/// 补场从 96% 放大到位（微缩放，不做 0 → 1 的"弹入"）
const kInfoBlockScaleFrom = 0.96;

// ==================== 封面 Hero ====================

/// 封面从列表飞进播放页的时长
const kHeroFlightDur = Duration(milliseconds: 340);

/// 落地后列表侧封面的淡出（飞行中两端各有一份，收尾要抹掉痕迹）
const kCoverFadeOutDur = Duration(milliseconds: 220);

// ==================== 加载动画 ====================

/// 烟缕一个完整周期
const kSmokeCycle = Duration(milliseconds: 3200);

// ==================== 加载文案逐字特效 ====================

/// 相邻字符起步间隔
const kCopyCharStep = Duration(milliseconds: 24);

/// 单字入场时长
const kCopyCharDur = Duration(milliseconds: 200);

/// 单字从下方 4px 上移到位
const kCopyCharRisePx = 4.0;

/// 字数多时降级：间隔减半，整句才不会拖成长镜头
const kCopyCharStepDense = Duration(milliseconds: 12);
