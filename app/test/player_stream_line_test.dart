// 备用线路（backupUrl）解析与轮转决策单测（v2.45.0+，纯函数，无原生/网络依赖）：
// - streamLinesOf：一条流（dash video/audio 条目、durl 条目）的候选线路表
//   （首条 = 主线路，其后 = 备用线路，按出现顺序去重）
// - nextStreamLineIndex：游标推进（首条优先 / 顺序轮转 / 耗尽 → 需换批）
// - streamLineAt：取第 n 条线路（越界钳位到最后一条，保证 video/audio 成对推进）
// - shouldReloadStreamUrl：该轮转（false）还是该重取 playurl（true）
//
// 背景：改动前换源只有「重取 playurl」一条路，而重取回来的还是同一批线路
// （同一台 CDN）→ 单台 CDN 坏了就一直坏。B 站同一条流会下发多台 CDN 的地址
// （实测 video[0]：baseUrl `cn-bj-fx-01-02.bilivideo.com` vs backupUrl
// `upos-sz-mirrorhw.bilivideo.com`）；本批候选轮转完才重取 playurl。
// 决策逻辑见 lib/pages/player_page.dart 顶部「备用线路轮转决策」注释。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('streamLinesOf（一条流的候选线路：主线路在前 + 备用线路去重）', () {
    test('dash 条目：baseUrl 首条，backupUrl 按出现顺序跟在后面', () {
      final lines = streamLinesOf(const {
        'baseUrl': 'https://cdn-a.bilivideo.com/v.m4s?deadline=1',
        'backupUrl': [
          'https://cdn-b.bilivideo.com/v.m4s?deadline=1',
          'https://cdn-c.bilivideo.com/v.m4s?deadline=1',
        ],
      });
      expect(lines, [
        'https://cdn-a.bilivideo.com/v.m4s?deadline=1',
        'https://cdn-b.bilivideo.com/v.m4s?deadline=1',
        'https://cdn-c.bilivideo.com/v.m4s?deadline=1',
      ]);
    });

    test('snake_case 变体（base_url / backup_url）也能解析', () {
      final lines = streamLinesOf(const {
        'base_url': 'https://a.bilivideo.com/v.m4s',
        'backup_url': ['https://b.bilivideo.com/v.m4s'],
      });
      expect(lines, ['https://a.bilivideo.com/v.m4s', 'https://b.bilivideo.com/v.m4s']);
    });

    test('durl 条目（只有 url + backup_url，无 camelCase 变体）', () {
      final lines = streamLinesOf(const {
        'url': 'https://a.bilivideo.com/v.mp4',
        'backup_url': ['https://b.bilivideo.com/v.mp4'],
      });
      expect(lines, ['https://a.bilivideo.com/v.mp4', 'https://b.bilivideo.com/v.mp4']);
    });

    test('去重：备用线路与主线路重复 → 只保留一次', () {
      final lines = streamLinesOf(const {
        'baseUrl': 'https://a.bilivideo.com/v.m4s',
        'backupUrl': [
          'https://a.bilivideo.com/v.m4s', // 与主线路重复
          'https://b.bilivideo.com/v.m4s',
          'https://b.bilivideo.com/v.m4s', // 备用内部重复
        ],
      });
      expect(lines, ['https://a.bilivideo.com/v.m4s', 'https://b.bilivideo.com/v.m4s']);
    });

    test('空值/非字符串跳过（不产生空线路）', () {
      final lines = streamLinesOf(const {
        'baseUrl': 'https://a.bilivideo.com/v.m4s',
        'backupUrl': ['', null, 42, 'https://b.bilivideo.com/v.m4s'],
      });
      expect(lines, ['https://a.bilivideo.com/v.m4s', 'https://b.bilivideo.com/v.m4s']);
    });

    test('无备用线路 → 只有主线路一条', () {
      expect(streamLinesOf(const {'baseUrl': 'https://a.bilivideo.com/v.m4s'}),
          ['https://a.bilivideo.com/v.m4s']);
    });

    test('什么都没有 → 空表（调用方按「无候选」处理）', () {
      expect(streamLinesOf(const {}), isEmpty);
      expect(streamLinesOf(const {'backupUrl': ['https://b.bilivideo.com/v.m4s']}),
          isEmpty,
          reason: '只有备用线路没有主线路的畸形条目：不做「主线路兜底猜测」');
    });
  });

  group('nextStreamLineIndex（游标推进：首条优先 → 顺序 → 耗尽）', () {
    test('首条优先：本批还没用过（-1）→ 0', () {
      expect(nextStreamLineIndex(lineCount: 3, usedIndex: -1), 0);
      expect(nextStreamLineIndex(lineCount: 1, usedIndex: -1), 0);
    });

    test('按顺序轮转：0→1→2', () {
      expect(nextStreamLineIndex(lineCount: 3, usedIndex: 0), 1);
      expect(nextStreamLineIndex(lineCount: 3, usedIndex: 1), 2);
    });

    test('耗尽（下标越出候选表）→ null = 需要重取 playurl 换一批', () {
      expect(nextStreamLineIndex(lineCount: 3, usedIndex: 2), isNull);
      expect(nextStreamLineIndex(lineCount: 3, usedIndex: 99), isNull);
    });

    test('只有一条候选 → 用完首条即耗尽（换批才有别的线路）', () {
      expect(nextStreamLineIndex(lineCount: 1, usedIndex: 0), isNull);
    });

    test('空候选表（本地缓存 / 未取到网络流）→ null', () {
      expect(nextStreamLineIndex(lineCount: 0, usedIndex: -1), isNull);
      expect(nextStreamLineIndex(lineCount: 0, usedIndex: 0), isNull);
    });

    test('负数 lineCount 防御 → null', () {
      expect(nextStreamLineIndex(lineCount: -1, usedIndex: -1), isNull);
    });
  });

  group('streamLineAt（取第 n 条：越界钳位，保证 video/audio 成对推进）', () {
    const lines = ['v0', 'v1', 'v2'];

    test('正常下标取下标那条', () {
      expect(streamLineAt(lines, 0), 'v0');
      expect(streamLineAt(lines, 2), 'v2');
    });

    test('越界 → 钳位到最后一条（候选短的轨停在自己末条上）', () {
      expect(streamLineAt(lines, 3), 'v2');
      expect(streamLineAt(lines, 99), 'v2');
    });

    test('负数 → 首条', () {
      expect(streamLineAt(lines, -1), 'v0');
    });

    test('空表 → null', () {
      expect(streamLineAt(const [], 0), isNull);
    });
  });

  group('shouldReloadStreamUrl（轮转 vs 重取 playurl）', () {
    test('线路报错 + 还有备用线路 → 轮转（不重取）', () {
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.lineError, hasNextLine: true),
        isFalse,
      );
    });

    test('线路报错 + 本批候选耗尽 → 重取 playurl 换一批', () {
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.lineError, hasNextLine: false),
        isTrue,
      );
    });

    test('URL 将到期（主动预取）→ 一律重取：备用线路与当前线路 deadline 相同，'
        '轮转延长不了有效期', () {
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.deadline, hasNextLine: true),
        isTrue,
      );
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.deadline, hasNextLine: false),
        isTrue,
      );
    });
  });

  group('镜像判定：可恢复错误码（与原生 DashExoPlayer.isRecoverableSourceError 同步）', () {
    test('2001/2002 属于可恢复类（网络 IO 兜底桶）', () {
      expect(kRecoverableNativeErrorCodes, contains(2001));
      expect(kRecoverableNativeErrorCodes, contains(2002));
      expect(kExoErrorIoNetworkConnectionFailed, 2001);
      expect(kExoErrorIoNetworkConnectionTimeout, 2002);
    });

    test('不含 2000（IO_UNSPECIFIED：HTTP 路径会被改写成 2001，真留 2000 的多是'
        '本地文件）/ 2005（文件不存在）/ 解析 4001 / 解码 3001', () {
      for (final code in const [2000, 2005, 4001, 3001]) {
        expect(kRecoverableNativeErrorCodes, isNot(contains(code)),
            reason: '$code 不该被当成可自动恢复（重试无意义）');
      }
    });
  });
}
