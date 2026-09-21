// 乐观写入队列（WhitelistWriteQueue）单元测试（v2.35.0）：
// - 串行：同一时刻只有一次远端写在飞（连点两次不会并发 PATCH 互相覆盖）
// - 合并：在飞期间的连续提交只保留**最后一份**，中间态跳过
// - 顺序：先落本地缓存，再写远端
// - 失败：排空后提示一次 + 返回 false；有更新的快照排队时不报旧失败
// - 缓存写失败不影响远端写、也不抛（缓存只是兜底）
//
// 用 GithubApi 替身（覆写 saveToGist）与假同步服务，不触网、不碰原生插件。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/whitelist_write_queue.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 带标记的整份白名单快照：拿合集名当"第几次提交"的标记，
/// 便于断言"最后写上去的是哪一份"。
WhitelistData _snap(String tag) => WhitelistData(
      version: 4,
      updatedAt: '2026-09-20T00:00:00Z',
      videos: const <WhitelistVideo>[],
      collections: [
        CollectionInfo(name: tag, createdAt: '2026-09-01T00:00:00Z'),
      ],
      upowners: const <Upowner>[],
    );

/// 快照标记（合集名）。
String _tagOf(WhitelistData data) => data.collections.first.name;

/// GithubApi 替身：记录每次远端写、可闸门化（模拟"网络卡住"）、可置失败。
class _FakeGithub extends GithubApi {
  _FakeGithub() : super(dio: Dio());

  final List<WhitelistData> saved = [];

  /// 非 null 时每次写都先等它（测试用来精确控制"在飞"的时机）。
  Completer<void>? gate;

  /// true → 抛 [GithubApiException]（模拟 HTTP 500 一类失败）。
  bool fail = false;

  int inFlight = 0;

  /// 历史上同时"在飞"的最大并发数（必须恒为 1 = 串行）。
  int maxInFlight = 0;

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    saved.add(wl);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final g = gate;
      if (g != null) await g.future;
      if (fail) {
        throw const GithubApiException('GitHub 返回错误（HTTP 500）',
            statusCode: 500);
      }
      return true;
    } finally {
      inFlight--;
    }
  }
}

/// 假同步服务：记录本地缓存写入顺序，可置失败。
class _RecordingSync extends WhitelistSyncService {
  _RecordingSync(this.events) : super(dio: Dio());

  final List<String> events;
  final List<WhitelistData> cached = [];
  bool failCache = false;

  @override
  Future<void> saveToCache(WhitelistData data) async {
    events.add('cache:${_tagOf(data)}');
    if (failCache) throw StateError('disk full');
    cached.add(data);
  }
}

/// 轮询等待 [predicate] 成立（最多 ~1s），避免测试里到处写死时长。
Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待条件超时');
}

void main() {
  test('串行 + 合并：在飞期间连提两次，只补最后一份（不会互相覆盖）', () async {
    final github = _FakeGithub()..gate = Completer<void>();
    final events = <String>[];
    final sync = _RecordingSync(events);
    final queue = WhitelistWriteQueue(github: github, syncService: () => sync);

    // 第一份：开始写（远端卡住）
    final first = queue.submit(_snap('A'));
    await _until(() => github.saved.length == 1);
    expect(_tagOf(github.saved[0]), 'A');

    // 在飞期间连提 B、C：只该保留 C
    queue.submit(_snap('B'));
    final third = queue.submit(_snap('C'));

    // 放行：队列写完 A 之后直接写 C（B 合并掉）
    github.gate!.complete();
    github.gate = null;
    expect(await third, isTrue);
    expect(await first, isTrue, reason: '连续提交共享同一次排空的 Future');

    expect(
      github.saved.map(_tagOf).toList(),
      ['A', 'C'],
      reason: '中间态 B 被合并（B 一定是 A 与 C 之间的中间快照）',
    );
    expect(github.maxInFlight, 1, reason: '同一时刻只有一次 PATCH 在飞');
    expect(
      events,
      ['cache:A', 'cache:C'],
      reason: '每份真正写出的快照都先落本地缓存；顺序 = 缓存 → 远端',
    );
  });

  test('本地缓存写入失败不阻断远端写（缓存只是兜底）', () async {
    final github = _FakeGithub();
    final events = <String>[];
    final sync = _RecordingSync(events)..failCache = true;
    final queue = WhitelistWriteQueue(github: github, syncService: () => sync);

    expect(await queue.submit(_snap('A')), isTrue);
    expect(github.saved.length, 1);
    expect(sync.cached, isEmpty);
  });

  test('远端写失败：排空后提示一次 + 返回 false（本地缓存照写）', () async {
    final github = _FakeGithub()..fail = true;
    final errors = <String>[];
    final sync = _RecordingSync([]);
    final queue = WhitelistWriteQueue(
      github: github,
      syncService: () => sync,
      onError: errors.add,
    );

    expect(await queue.submit(_snap('A')), isFalse);
    expect(errors, ['GitHub 返回错误（HTTP 500）']);
    expect(sync.cached.map(_tagOf).toList(), ['A'],
        reason: '远端失败不回滚：本地缓存仍然是最新的一份');
  });

  test('失败后紧接着有更新的快照：不报旧失败，只报最终结果', () async {
    final github = _FakeGithub()
      ..fail = true
      ..gate = Completer<void>();
    final errors = <String>[];
    final queue = WhitelistWriteQueue(
      github: github,
      syncService: () => _RecordingSync([]),
      onError: errors.add,
    );

    final first = queue.submit(_snap('A')); // 这一份会失败
    await _until(() => github.saved.length == 1);
    github.fail = false; // 网络恢复
    final second = queue.submit(_snap('B')); // 排队中的更新快照，会成功

    github.gate!.complete();
    github.gate = null;

    expect(await first, isTrue, reason: '最终状态同步成功');
    expect(await second, isTrue);
    expect(errors, isEmpty, reason: '旧失败已被更新的快照覆盖，不该白喊一声');
  });

  test('队列空闲后再提交：新开一轮排空（不丢唤醒）', () async {
    final github = _FakeGithub();
    final queue = WhitelistWriteQueue(
      github: github,
      syncService: () => _RecordingSync([]),
    );

    expect(await queue.submit(_snap('A')), isTrue);
    expect(queue.idle, isTrue);
    expect(await queue.submit(_snap('B')), isTrue);
    expect(github.saved.map(_tagOf).toList(), ['A', 'B']);
    expect(github.maxInFlight, 1);
  });
}
