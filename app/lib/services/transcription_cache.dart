/// whisper 转写结果持久化缓存。
///
/// 文件：`<应用支持目录>/transcription_cache/transcription_<bvid>_<pageIndex>.json`，
/// 内容为 cues 数组 JSON：`[{"from":秒,"to":秒,"content":"..."}, ...]`。
///
/// 语义：同一视频同一集只转写一次；读取时容错——文件不存在 / 损坏 /
/// 解析失败一律视为无缓存（返回 null），单条字段异常跳过该条。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/subtitle.dart';

/// 转写结果缓存（根目录可注入，测试不依赖 path_provider 插件）。
class TranscriptionCache {
  TranscriptionCache({Directory? rootDir}) : _rootDirOverride = rootDir;

  /// 缓存目录名（应用支持目录下）。
  static const String dirName = 'transcription_cache';

  final Directory? _rootDirOverride;

  Future<Directory> _rootDir() async =>
      _rootDirOverride ?? await getApplicationSupportDirectory();

  /// 缓存文件名：`transcription_<bvid>_<pageIndex>.json`。
  String fileName(String bvid, int pageIndex) =>
      'transcription_${bvid}_$pageIndex.json';

  Future<File> _fileFor(String bvid, int pageIndex) async =>
      File('${(await _rootDir()).path}/$dirName/${fileName(bvid, pageIndex)}');

  /// 读取某集转写缓存；无缓存 / 文件损坏 / 解析失败 → null
  /// （损坏容错：不抛异常，调用方按「无转写」处理）。
  Future<List<SubtitleCue>?> getCached(String bvid, int pageIndex) async {
    try {
      final f = await _fileFor(bvid, pageIndex);
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      if (json is! List) return null;
      final cues = <SubtitleCue>[];
      for (final item in json) {
        if (item is! Map<String, dynamic>) continue;
        try {
          cues.add(SubtitleCue.fromJson(item));
        } on FormatException {
          // 单条字段异常跳过，不影响其余条目
        }
      }
      if (cues.isEmpty) return null;
      debugPrint('[transcription_cache] 命中 ${fileName(bvid, pageIndex)} '
          '${cues.length} 条');
      return cues;
    } catch (_) {
      return null; // 损坏/读取失败：视为无缓存
    }
  }

  /// 写入某集转写缓存（覆盖式；cues 为空不写）。
  Future<void> save(String bvid, int pageIndex, List<SubtitleCue> cues) async {
    if (cues.isEmpty) return;
    final f = await _fileFor(bvid, pageIndex);
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode([
        for (final c in cues)
          {'from': c.from, 'to': c.to, 'content': c.content},
      ]),
      flush: true,
    );
  }

  /// 清除某集转写缓存（「重新转写」前调用；文件不存在/删除失败静默，
  /// 残留旧文件由下次 save 覆盖兜底）。
  Future<void> clear(String bvid, int pageIndex) async {
    try {
      final f = await _fileFor(bvid, pageIndex);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删除失败静默（下次 save 覆盖旧内容）
    }
  }
}
