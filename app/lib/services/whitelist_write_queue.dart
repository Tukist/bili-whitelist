/// 白名单「乐观写入」队列：本地立刻生效，远端写排队后台进行（v2.35.0）。
///
/// 背景：管理写操作（新建合集 / 视频入合集 / 移动 / 重命名 / 删除 / 排序）
/// 原先一律 `await saveToGist(next)` **成功之后**才 `setState` 刷新界面——
/// 国内访问 api.github.com 一次 PATCH 常要几百毫秒到几秒，用户点完要盯着
/// 旧界面等（"为什么创建和加入合集会有延迟"）。这里把「写远端」挪到后台：
///
/// - 调用方只管把**新的整份白名单**交给队列，自己立刻刷新内存与界面；
/// - 队列串行执行「写本地缓存 → PATCH Gist」，失败经 [onError] 提示；
/// - **失败不回滚**：本地已经生效，远端失败只提示"未同步到 Gist"——
///   回滚会把用户刚做完的操作凭空抹掉，比"没同步上"难接受得多（他至少还能
///   在本机继续用，重新点一次也就同步了）。
///
/// 并发/顺序安全：每次提交的都是**一次完整快照**（调用方基于最新内存数据
/// 构造），所以队列只保留**最后一份**待写数据（[_pending]）：
/// - 同一时刻只有一次 PATCH 在飞 → 不会出现两次 read-modify-write 互相覆盖；
/// - 在飞期间又来新提交 → 只把待写快照换成最新那份，中间态直接跳过
///   （被跳过的快照一定被后一份完整快照包含，不会丢改动）。
///
/// ⚠️ TODO（已知限制，本批次刻意不修，理由如下）：这份串行只罩住**本队列**
/// 发出的写。别的入口仍在写同一份 Gist——最典型的是 [WhitelistWriter.addVideo]
/// （搜索页「加入」/ 信箱右滑 / UP 主长按 / 链接导入），它是「先 GET 整份查重、
/// 再 PATCH 整份」的 read-modify-write。所以：
///   乐观写 PATCH 还在飞（国内实测 **6.0~9.6 秒**）时，用户在搜索页「加入」
///   一个视频 → 那边 GET 到的还是**没有**刚新建合集（或刚改过的合集）的旧快照
///   → 那一次 PATCH 会把本地这次改动静默覆盖掉。
/// 改动前这种竞争同样存在，只是窗口小得多（老代码是"等写完才让用户继续操作"），
/// 乐观更新把窗口拉长到了整个 PATCH 期间。
/// 为什么不顺手修：要让两边互斥，得把「本地缓存 + Gist 写」抽成一把跨入口的锁
/// （或把 addVideo 的远端查重换成基于本地内存的乐观查重），那会同时改动搜索页 /
/// 信箱 / UP 主页 / 导入四条链路的数据一致性语义，超出「创建/加入合集的延迟」
/// 这件事的范围，得单独立项（先把锁或"以本地为准"的合并策略设计清楚再动）。
library;

import 'package:flutter/foundation.dart';

import '../api/github_api.dart';
import '../models/whitelist_video.dart';
import '../services/service_locator.dart';
import '../sync/whitelist_freshness.dart';
import '../sync/whitelist_source.dart';

class WhitelistWriteQueue {
  /// Gist 写入口（与页面共用同一个实例，测试注入同一份替身）。
  final GithubApi github;

  /// 同步服务（本地缓存落盘用）。用函数惰性取，构造时不依赖单例，
  /// 测试也能在 `ServiceLocator.overrideSyncService` 之后才真正取到替身。
  final WhitelistSyncService Function() _syncService;

  /// 远端写失败的提示回调（message 可直接展示）。null = 只记日志不提示。
  final void Function(String message)? onError;

  /// 待写快照（null = 没有新提交）。只保留最后一份，见类注释。
  WhitelistData? _pending;

  /// 正在跑的排空循环（null = 空闲）。多次提交共享同一个 Future。
  Future<bool>? _running;

  WhitelistWriteQueue({
    GithubApi? github,
    WhitelistSyncService Function()? syncService,
    this.onError,
  })  : github = github ?? GithubApi(),
        _syncService = syncService ?? (() => ServiceLocator.syncService);

  /// 队列是否空闲（调试/测试用）。
  bool get idle => _running == null;

  /// 提交一次写入（乐观）：调用方已经刷新了自己的内存与界面，这里只负责落库。
  ///
  /// 返回的 Future 在**队列排空后**完成，值 = 最后一次远端写是否成功。
  /// 页面**不要 await** 它（await 就是把延迟又搬回来了），测试可以 await
  /// 来断言顺序与失败处理；连续提交共享同一次排空的 Future。
  ///
  /// **陈旧快照门禁（v2.43.0）**：当前展示的数据被判定为陈旧离线快照时，
  /// 这里**直接拒掉**——不写本地缓存、不发 PATCH。页面已经先拦一道（在
  /// setState 之前，见 `_saveAndRefresh`），这里再拦一道是因为本队列才是
  /// 「用整份快照覆盖远端」的真正出口：任何绕过页面的调用方都会在这里被挡，
  /// 本地缓存文件也不会被陈旧数据污染（否则下次启动会把污染当成"已知最新"）。
  Future<bool> submit(WhitelistData data) {
    final blocked = WhitelistFreshness.instance.writeBlockReason;
    if (blocked != null) {
      debugPrint('[wq] 陈旧快照：拒绝排队（0 PATCH / 0 本地缓存写）');
      onError?.call(blocked);
      return Future.value(false);
    }
    _pending = data;
    return _running ??= _drain();
  }

  /// 串行排空：一次一份，直到没有待写快照。
  ///
  /// ⚠️ 循环退出要点：`while` 里每次 `await` 之后都重新读 [_pending]，
  /// 所以「在飞期间的新提交」一定会被这一轮吃掉；两轮之间的 `_pending = null`
  /// 与收尾的 `_running = null` 之间**没有 await**（单线程下不会插进新提交），
  /// 因此不会丢唤醒（丢唤醒 = 提交了却永远不写）。
  Future<bool> _drain() async {
    var synced = true; // 最后一次远端写的结果（= 队列排空后的真实状态）
    String? error; // 最后一次失败的原因（排空时才提示，见下）
    try {
      while (true) {
        final data = _pending;
        if (data == null) break;
        _pending = null;

        // 1) 本地缓存：先落盘，保证「立刻生效」在重启后也还在。
        //    失败静默——缓存只是下次启动/断网时的兜底，真源是 Gist。
        try {
          await _syncService().saveToCache(data);
        } catch (e) {
          debugPrint('[wq] 本地缓存写入失败（忽略）: $e');
        }

        // 2) 远端 PATCH。失败先攒着：如果紧接着还有更新的快照在排队，
        //    这一份的失败没有意义（马上会被最新状态覆盖），不该弹提示。
        //    开始/结束都打时间戳（真机取证用：这一段就是用户**不再等**的那段）。
        final t0 = DateTime.now().millisecondsSinceEpoch;
        debugPrint('[wq] 远端写开始 t=$t0'
            '（${data.videos.length} 视频 / ${data.collections.length} 合集）');
        try {
          final ok = await github.saveToGist(data);
          if (ok) {
            synced = true;
            error = null;
          } else {
            synced = false;
            error = '保存失败，请重试';
          }
        } on GithubApiException catch (e) {
          synced = false;
          error = e.message;
        } catch (e) {
          synced = false;
          error = '$e';
        }
        debugPrint('[wq] 远端写结束 t=${DateTime.now().millisecondsSinceEpoch}'
            '（耗时 ${DateTime.now().millisecondsSinceEpoch - t0}ms，'
            '${error == null ? '成功' : '失败：$error'}）');
      }
    } finally {
      _running = null;
    }
    // 队列真空了才提示：一次失败连着一串提交只喊一声（不刷屏）。
    if (error != null) onError?.call(error);
    return synced;
  }
}
