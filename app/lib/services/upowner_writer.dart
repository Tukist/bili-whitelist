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

/// UP 主写入服务（白名单 Gist 写路径）。
///
/// 异常契约：
/// - [add] / [removeByMid] / [updateLastSeen]：Gist 读写失败抛
/// [GithubApiException]；B 站接口失败抛 [BiliApiException]；网络失败抛
/// [DioException]。
/// - 配置门禁：调用 [hasConfig] 自行判断（add 时也会再次校验并返回错误信息）。
class UpownerWriter {
  final GithubApi github;

  UpownerWriter({GithubApi? github}) : github = github ?? GithubApi();

  /// token + gist_id 是否都已配置（写操作前调用）。
  Future<bool> hasConfig() => github.hasConfig();

  /// 把 UP 主加入白名单：mid 查重 → 合并 → saveToGist → 写本地缓存。
  /// 重复/未配置/保存失败返回 [UpownerWriteResult] 说明原因，不抛异常。
  Future<UpownerWriteResult> add(Upowner up) async {
    if (!await github.hasConfig()) {
      return const UpownerWriteResult(
        ok: false,
        message: '请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID',
      );
    }
    final current = await github.fetchFromGist();
    final data = current ?? WhitelistData.empty();
    // 查重（mid）
    if (data.upowners.any((u) => u.mid == up.mid)) {
      return UpownerWriteResult(
        ok: false,
        data: data,
        message: '已在白名单：${up.name}',
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
      message: '已加入：${up.name}',
    );
  }

  /// 按 mid 移除 UP 主：拉 Gist → 过滤 → saveToGist → 写本地缓存。
  Future<UpownerWriteResult> removeByMid(int mid) async {
    if (!await github.hasConfig()) {
      return const UpownerWriteResult(
        ok: false,
        message: '请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID',
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
        message: 'UP 主（mid=$mid）不在白名单中',
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
      message: '已移除 UP 主',
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
        message: '请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID',
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