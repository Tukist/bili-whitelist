/// 弹幕轨道分配器（v2.16.6+ 真碰撞分层，消除叠字）。
///
/// 纯 Dart 无 Flutter 依赖（可单测）。把弹幕区按行高切成 N 条水平轨道，
/// 每条轨道**只记录最后一条弹幕**的状态（O(1) 查询，无每帧重排）：
///
/// - 滚动轨道：最后一条的当前尾缘 x（右边缘，随帧向左推进）与速率；
///   新滚动弹幕入场时判定"整条生命周期内会不会追尾"（见 [DanmakuLanes]）。
/// - 顶部/底部轨道：各自记录该行剩余停留时间（停留中不可复用），新弹幕
///   取最靠上（底）的空闲行；行全忙 → 丢弃（滚动同理），丢弃计数累加供
///   日志/测试断言。
///
/// 位置语义与 danmaku_overlay.dart 一致：x 为文本**左缘**，滚动弹幕从
/// `x = screenWidth + entryGap` 起步向左（vx<0），尾缘 = x + 文本宽；
/// 尾缘 <= 0 视为整条已出屏（轨道腾空）。
library;

/// 弹幕横向轨道数/行高的布局参数由渲染层计算后传入，本类只管分配判定。
class DanmakuLanes {
  /// 屏幕可视宽度（px），滚动弹幕入场与出屏判定的参照。
  final double screenWidth;

  /// 滚动弹幕入场起点距右缘的间隙（px，屏外起步防闪现）。
  final double entryGap;

  /// 滚动轨道数。
  final int scrollLanes;

  /// 顶部轨道数（顶部弹幕纵向堆叠行数）。
  final int topLanes;

  /// 底部轨道数。
  final int bottomLanes;

  /// 顶部/底部弹幕停留时长（秒；停留期间行被占用）。
  final double staySec;

  // ---- 滚动轨道状态：下标 i 对应轨道 i ----
  /// 最后一条弹幕的当前尾缘 x；<= 0 表示该轨已腾空（可分配）。
  final List<double> _scrollTailX;

  /// 最后一条弹幕的速率 px/s（正值；向左移动的速率）。
  final List<double> _scrollSpeed;

  // ---- 顶部/底部行状态：剩余停留秒数，<= 0 表示空 ----
  final List<double> _topRemain;
  final List<double> _bottomRemain;

  /// 各类型被丢弃的累计条数（轨道全忙放不下 → 丢，防叠字优先）。
  int scrollDropped = 0;
  int topDropped = 0;
  int bottomDropped = 0;

  DanmakuLanes({
    required this.screenWidth,
    this.entryGap = 10,
    required this.scrollLanes,
    required this.topLanes,
    required this.bottomLanes,
    this.staySec = 3.5,
  })  : assert(scrollLanes >= 1 && topLanes >= 1 && bottomLanes >= 1),
        _scrollTailX = List<double>.filled(scrollLanes, 0),
        _scrollSpeed = List<double>.filled(scrollLanes, 0),
        _topRemain = List<double>.filled(topLanes, 0),
        _bottomRemain = List<double>.filled(bottomLanes, 0);

  /// 每帧推进：滚动尾缘向左移动；顶/底行剩余停留递减。
  /// 渲染层在 tick 推进弹幕位置后调用一次。
  void advance(double dt) {
    for (var i = 0; i < scrollLanes; i++) {
      if (_scrollTailX[i] > 0) {
        _scrollTailX[i] -= _scrollSpeed[i] * dt;
        // 尾缘越过左缘 = 整条已出屏 → 腾空（归 0），下一条可用
        if (_scrollTailX[i] <= 0) {
          _scrollTailX[i] = 0;
          _scrollSpeed[i] = 0;
        }
      }
    }
    for (var i = 0; i < topLanes; i++) {
      if (_topRemain[i] > 0) _topRemain[i] -= dt;
    }
    for (var i = 0; i < bottomLanes; i++) {
      if (_bottomRemain[i] > 0) _bottomRemain[i] -= dt;
    }
  }

  /// 为一条「宽 [textWidth]、速率 [speed]」的新滚动弹幕挑选可用轨道：
  /// 返回轨道下标；全部轨道都被占且会追尾 → null（丢弃）。
  ///
  /// ## 碰撞判据（准确追尾判定，O(1)）
  /// 记后车（新弹幕）左缘起点 x0 = screenWidth + entryGap，速率 vn；前车
  /// （该轨道最后一条）尾缘当前 tail，速率 vp。两车均向左匀速，分离量
  /// `s(t) = 后车左缘 - 前车尾缘 = (x0 - tail) + (vp - vn) * t`。
  /// - s < 0 即重叠（后车左缘侵入前车区间）。初始 tail > x0（前车尾缘还
  ///   没过入口）→ 起步即叠 → 拒；初始分离后：
  /// - vn <= vp（后车不更快）→ s(t) 不减小，永不追尾 → 可用；
  /// - vn > vp → 追尾时刻 tCatch = (x0 - tail) / (vn - vp)；只要前车尾缘
  ///   先出屏（tClear = tail / vp）→ 可用，否则同轨必叠 → 拒。
  int? pickScrollLane({required double textWidth, required double speed}) {
    final x0 = screenWidth + entryGap;
    for (var i = 0; i < scrollLanes; i++) {
      final tail = _scrollTailX[i];
      if (tail <= 0) return i; // 空轨直接可用
      final vp = _scrollSpeed[i];
      final dx = x0 - tail; // 初始分离（>0：前车尾缘已让出入口）
      if (dx < 0) continue; // 前车还堵在入口 → 起步即叠
      if (speed <= vp) return i; // 后车不更快 → 分离保持
      final tCatch = dx / (speed - vp);
      final tClear = tail / vp;
      if (tCatch >= tClear) return i; // 追上时前车已完全出屏
    }
    scrollDropped++;
    return null;
  }

  /// 新滚动弹幕落轨后登记：记录其初始尾缘与速率（覆盖原 last）。
  void markScrollLane(int lane, {required double textWidth, required double speed}) {
    _scrollTailX[lane] = screenWidth + entryGap + textWidth;
    _scrollSpeed[lane] = speed;
  }

  /// 顶部弹幕取行：优先最上空闲行（0 = 最顶行）；全忙 → null（丢弃）。
  int? pickTopLane() {
    for (var i = 0; i < topLanes; i++) {
      if (_topRemain[i] <= 0) return i;
    }
    topDropped++;
    return null;
  }

  /// 顶部弹幕落行后登记占用（停留 [staySec] 后释放）。
  void markTopLane(int lane) => _topRemain[lane] = staySec;

  /// 底部弹幕取行：优先最靠上行（0 = 底区最上面一行，先让给新弹幕）；
  /// 全忙 → null（丢弃）。
  int? pickBottomLane() {
    for (var i = 0; i < bottomLanes; i++) {
      if (_bottomRemain[i] <= 0) return i;
    }
    bottomDropped++;
    return null;
  }

  /// 底部弹幕落行后登记占用。
  void markBottomLane(int lane) => _bottomRemain[lane] = staySec;

  /// 当前仍被占用的滚动轨道数（供日志断言「活跃 ≤ 轨道总数 → 不叠」）。
  int get busyScrollLanes {
    var n = 0;
    for (final t in _scrollTailX) {
      if (t > 0) n++;
    }
    return n;
  }
}
