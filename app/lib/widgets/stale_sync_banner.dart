import 'package:flutter/material.dart';

import '../sync/whitelist_freshness.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// 「你正在看的是**陈旧的离线快照**」常驻提示横幅（v2.44.0）。
///
/// ## 解决的是什么
/// v2.43.0 把门禁做在了**写**侧：用户动手改的那一刻弹一句「这次修改没有保存」。
/// 但用户历史上两次投诉——「我在白名单里面还是只看到 2 个人」「白名单 UP 主会
/// 时不时自动清空」——都不是"改不动"引起的，而是**看着旧/空的数据毫不知情**。
/// 也就是说：在用户动手之前，界面从来没有告诉过他"这份数据可能不是最新的"。
/// 本组件补的就是这一步：把 `SyncResult.stale` 渲染成一条**一直挂着**的横幅。
///
/// ## 为什么是常驻横幅，而不是 SnackBar
/// 陈旧是**持续状态**（离线冷启动后它一直在，直到真的同步成功），不是一次性
/// 事件。一次性提示划走就再也看不见了，等于没提示。所以这里是一条占位横幅：
/// [stale] 为 true 时显示，同步成功后由调用方传 false 让它消失。
///
/// ## 文案为什么不进可编辑文案库
/// [kStaleSnapshotBannerMessage] 与写入门禁那句
/// [kStaleSnapshotWriteBlockedMessage] 是同一件事的两种说法（一个"看的时候"、
/// 一个"改的时候"），都属于**数据安全说明**而不是空态风味文案：改错会让用户
/// 误解为什么改不动。两者放在同一处（`sync/whitelist_freshness.dart`）作为
/// 唯一出口，不受设置页文案库影响。
///
/// ## 两个页面共用
/// 首页「合集」tab 与合集内部页（`CollectionPage`）共用同一个组件，不复制两份。
/// 合集页只传 [stale] / [onResync]（那一页没有"数据时间/来源"的出口，时间信息的
/// 唯一出口仍在首页的信息条上）。
class StaleSyncBanner extends StatelessWidget {
  /// 当前展示的数据是否被**确证**陈旧（来自 `SyncResult.stale`，
  /// 判据在 [WhitelistFreshness.isBehind]）。
  final bool stale;

  /// 「立即同步」回调；为空 → 只提示、不给动作。
  final VoidCallback? onResync;

  const StaleSyncBanner({
    super.key,
    required this.stale,
    this.onResync,
  });

  @override
  Widget build(BuildContext context) {
    // 不陈旧 → 完全不占位（调用方可以无脑放进布局，不用自己写 if）。
    if (!stale) return const SizedBox.shrink();

    final palette = context.palette;
    return Container(
      width: double.infinity,
      // 点缀墨（赤陶）的固定职责是「时间与新鲜度」（见 app_tokens 的语义约定），
      // 这里正是它最正当的用法：说的就是"这份数据的时间不对"。
      color: palette.accentWash,
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace4, kSpace4, kSpace4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // 与首行文字对齐（图标 18，行高 1.4 × 12 ≈ 17）
            padding: const EdgeInsets.only(top: 3),
            child: Icon(Icons.cloud_off_outlined,
                size: 18, color: palette.accentDeep),
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: kSpace8),
              child: Text(
                kStaleSnapshotBannerMessage,
                style: kTypeBodyS.copyWith(color: palette.accentDeep),
              ),
            ),
          ),
          if (onResync != null)
            TextButton(
              // FilledButton 太抢戏（页面上还有"新建合集"等主操作），
              // 但动作必须一眼可见 → 文字按钮 + 点缀墨加深色，触摸目标 ≥ 48dp
              // 由主题的 materialTapTargetSize.padded 保证。
              onPressed: onResync,
              style: TextButton.styleFrom(foregroundColor: palette.accentDeep),
              child: const Text('立即同步'),
            ),
        ],
      ),
    );
  }
}
