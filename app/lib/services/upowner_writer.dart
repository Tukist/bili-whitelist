/// UP 主白名单写入服务：「搜索结果一键加入白名单 UP 主」与
/// 「信箱检查后批量更新 lastSeenBvid」共用同一份实现（拉 Gist → 改 → 写回）。
///
/// 与 [WhitelistWriter]（视频）平行：UP 主和视频在 Gist 同份 JSON 内共存
/// 但通过 `addUpowner` / `removeUpowner` / `updateUpownerLastSeen` 隔离写，
/// 避免两路写并发冲突。
library;

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import 'service_locator.dart';

/// 「UP 主加入/更新」一次操作的结果。
///
/// - [ok]=true：成功，[data] 为新白名单
/// - [ok]=false：业务失败（重复 / 未配置 / 保存失败），[message] 可直接展示
class UpownerWriteResult {
  final bool ok;
  final WhitelistData? data;
  final String message;

  const UpownerWriteResult({
    required this.ok,
    this.data,
    required this.message,
  });
}

/// 「UP 主批量加入」的结果（v2.17.12+，导入 B 站关注列表用）。
///
/// - [ok]=false：配置缺失等整体失败，[message] 可直接展示（未开始写盘）
/// - [ok]=true：[added] 实际新增个数；[skipped] 已存在白名单被跳过个数
///   （含所选内互相重复）；[data] 可能为 null（无需写盘时也可能为 null）
class UpownerBatchResult {
  final bool ok;
  final WhitelistData? data;
  final String message;
  final int added;
  final int skipped;

  const UpownerBatchResult({
    required this.ok,
    this.data,
    required this.message,
    this.added = 0,
    this.skipped = 0,
  });
}

/// UP 主写入服务（白名单 Gist 写路径）。
///
/// 异常契约：
/// - [add] / [addBatch] / [removeByMid] / [updateLastSeen]：Gist 读写失败抛
/// [GithubApiException]；B 站接口失败抛 [BiliApiException]；网络失败抛
/// [DioException]。
/// - 配置门禁：调用 [hasConfig] 自行判断（add 时也会再次校验并返回错误信息）。
class UpownerWriter {
  final GithubApi github;

  /// B 站 API（导入「我关注的 UP」拉列表用；测试可注入 mock）。
  final BiliApi api;

  UpownerWriter({GithubApi? github, BiliApi? api})
    : github = github ?? GithubApi(),
      api = api ?? BiliApi();

  /// token + gist_id 是否都已配置（写操作前调用）。
  Future<bool> hasConfig() => github.hasConfig();

  /// 把 UP 主加入白名单：mid 查重 → 合并 → saveToGist → 写本地缓存。
  /// 重复/未配置/保存失败返回 [UpownerWriteResult] 说明原因，不抛异常。
  Future<UpownerWriteResult> add(Upowner up) async {
    if (!await github.hasConfig()) {
      return const UpownerWriteResult(
        ok: false,
        message: '请先到底部导航「个人」页配置 GitHub token 与 Gist ID',
      );
    }
    final current = await github.fetchFromGist();
    final data = current ?? WhitelistData.empty();
    // 查重（mid）
    if (data.upowners.any((u) => u.mid == up.mid)) {
      return UpownerWriteResult(
        ok: false,
        data: data,
        message: '「${up.name}」已在白名单（无需重复关注）',
      );
    }
    final next = addUpowner(data, up);
    final ok = await github.saveToGist(next);
    if (!ok) {
      return UpownerWriteResult(
        ok: false,
        data: data,
        message: '保存到 Gist 失败，请重试',
      );
    }
    await ServiceLocator.syncService.saveToCache(next);
    return UpownerWriteResult(
      ok: true,
      data: next,
      message: '已关注：${up.name}',
    );
  }

  /// 批量加入 UP 主（v2.17.12+，导入 B 站关注列表用）。
  ///
  /// 与逐个 [add] 的区别：**只拉一次 Gist → 查重合并 → 一次 saveToGist →
  /// 一次写缓存**（导入可能上百个，逐个 add 会 N 次拉/写 Gist）。
  ///
  /// - mid 已在白名单 / 所选内部重复 → 跳过（计入 [UpownerBatchResult.skipped]）
  /// - 全部被跳过（无需写盘）→ ok=true、added=0、data=null（不发写请求）
  /// - 未配置 → ok=false（不发 Gist 请求，[message] 引导配置）
  /// - Gist 拉取/保存/缓存失败 → 抛 [GithubApiException]（由调用方分类提示）
  Future<UpownerBatchResult> addBatch(List<Upowner> ups) async {
    // 清洗入参：去掉无效条目（mid<=0 或空名）与所选内部重复
    final seen = <int>{};
    final clean = <Upowner>[];
    for (final u in ups) {
      if (u.mid <= 0 || u.name.trim().isEmpty) continue;
      if (seen.contains(u.mid)) continue;
      seen.add(u.mid);
      clean.add(u);
    }
    if (clean.isEmpty) {
      return const UpownerBatchResult(
        ok: true,
        message: '所选 UP 无效（无 mid/无名字），未添加',
      );
    }
    if (!await github.hasConfig()) {
      return const UpownerBatchResult(
        ok: false,
        message: '请先到底部导航「个人」页配置 GitHub token 与 Gist ID',
      );
    }
    final current = await github.fetchFromGist();
    final data = current ?? WhitelistData.empty();
    final existingMids = data.upowners.map((u) => u.mid).toSet();
    final toAdd = <Upowner>[];
    for (final u in clean) {
      if (existingMids.contains(u.mid)) continue; // 已在白名单 → 跳过
      toAdd.add(u);
    }
    final skipped = clean.length - toAdd.length;
    if (toAdd.isEmpty) {
      return UpownerBatchResult(
        ok: true,
        data: data,
        message: '所选 UP 已全部在白名单（无需添加）',
        added: 0,
        skipped: skipped,
      );
    }
    final next = data.copyWith(upowners: [...data.upowners, ...toAdd]);
    final ok = await github.saveToGist(next);
    if (!ok) {
      return UpownerBatchResult(
        ok: false,
        data: data,
        message: '保存到 Gist 失败，请重试',
        added: 0,
        skipped: skipped,
      );
    }
    await ServiceLocator.syncService.saveToCache(next);
    return UpownerBatchResult(
      ok: true,
      data: next,
      message: '已关注 ${toAdd.length} 位 UP 主',
      added: toAdd.length,
      skipped: skipped,
    );
  }

  /// 按 mid 移除 UP 主：拉 Gist → 过滤 → saveToGist → 写本地缓存。
  Future<UpownerWriteResult> removeByMid(int mid) async {
    if (!await github.hasConfig()) {
      return const UpownerWriteResult(
        ok: false,
        message: '请先到底部导航「个人」页配置 GitHub token 与 Gist ID',
      );
    }
    final current = await github.fetchFromGist();
    if (current == null) {
      return const UpownerWriteResult(ok: false, message: '白名单为空');
    }
    final next = removeUpowner(current, mid);
    if (identical(next, current)) {
      return UpownerWriteResult(
        ok: false,
        data: current,
        message: '该 UP 主未在白名单（未关注）',
      );
    }
    final ok = await github.saveToGist(next);
    if (!ok) {
      return UpownerWriteResult(
        ok: false,
        data: current,
        message: '保存到 Gist 失败，请重试',
      );
    }
    await ServiceLocator.syncService.saveToCache(next);
    return UpownerWriteResult(
      ok: true,
      data: next,
      message: '已取消关注（已从白名单移除）',
    );
  }

  /// 信箱批量更新 lastSeen：拉 Gist → 按 mid 写回 lastSeenBvid/lastSeenAt →
  /// saveToGist → 写本地缓存。单个 mid 不存在时跳过，不抛错。
  ///
  /// [updates]：键 = mid；值 = (lastSeenBvid, lastSeenAt)
  Future<UpownerWriteResult> updateLastSeenBatch(
    Map<int, ({String bvid, DateTime at})> updates,
  ) async {
    if (updates.isEmpty) {
      return UpownerWriteResult(ok: true, data: null, message: '无需更新');
    }
    if (!await github.hasConfig()) {
      return const UpownerWriteResult(
        ok: false,
        message: '请先到底部导航「个人」页配置 GitHub token 与 Gist ID',
      );
    }
    final current = await github.fetchFromGist();
    if (current == null) {
      return const UpownerWriteResult(ok: false, message: '白名单为空');
    }
    var changed = false;
    final nextUpowners = <Upowner>[];
    for (final u in current.upowners) {
      final patch = updates[u.mid];
      if (patch == null) {
        nextUpowners.add(u);
        continue;
      }
      nextUpowners.add(u.copyWith(
        lastSeenBvid: patch.bvid,
        lastSeenAt: patch.at,
      ));
      changed = true;
    }
    if (!changed) {
      return UpownerWriteResult(
        ok: true,
        data: current,
        message: '无需更新',
      );
    }
    final next = current.copyWith(upowners: nextUpowners);
    final ok = await github.saveToGist(next);
    if (!ok) {
      return UpownerWriteResult(
        ok: false,
        data: current,
        message: '保存到 Gist 失败，请重试',
      );
    }
    await ServiceLocator.syncService.saveToCache(next);
    return UpownerWriteResult(
      ok: true,
      data: next,
      message: '已更新 ${updates.length} 个 UP 主的检查进度',
    );
  }
}