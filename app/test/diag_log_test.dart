// DiagLog 环形落盘（v2.67.0）· 单元测试。
//
// 这一层是"用户报障 → 一键导出"的底座，出错的方式都很隐蔽（不抛异常、
// 静默失败），所以每条约定都单独钉住：
//
// - **接管**：`install()` 把旧 `debugPrint` 存起来，`write` 内部回调它
//   （logcat/IDE 输出与 `wrapWidth` 语义不变）；重复 install 不叠套；
// - **不劫持库加载期**：测试里临时替换 `debugPrint` 抓日志的用法照旧可用
//   （playview_api_test / update_service_test 就是这么抓的）；
// - **落盘**：`rootDirOverride` 生效、内容已脱敏、`enabled=false` 不写；
// - **轮转**：512KB × 最多 4 份、目录总量 5MB、删最旧；
// - **去重限流**：同 tag 同前缀 1 秒内只写 1 条（播放/信箱会刷屏）；
// - **崩溃路径**：`recordError` + `flushSync()` 之后立刻能在文件里读到；
// - **失败静默**：目录不可用时 write / flushSync / exportBundle 都不抛；
// - **导出**：zip 里有日志 + meta.txt，meta 带版本/条数/脱敏说明；
// - **原生碎片合并**：`native-crash-*.txt` 合入 diag 日志并删掉原文件。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/diag_log.dart';

late Directory _tmp;
late DebugPrintCallback _originalDebugPrint;

/// 静音控制台（install 会把这个空实现当成"旧 debugPrint"存起来）。
void _silent(String? message, {int? wrapWidth}) {}

Future<void> _boot({DebugPrintCallback? previous}) async {
  debugPrint = previous ?? _silent;
  DiagLog.rootDirOverride = _tmp;
  await DiagLog.install();
}

Directory get _logsDir => Directory('${_tmp.path}/logs');

List<File> _logFiles() {
  final dir = _logsDir;
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.log'))
      .toList();
}

/// 目录里所有日志拼起来（断言用）。
String _allLogText() => _logFiles().map((f) => f.readAsStringSync()).join('\n');

void main() {
  setUp(() {
    _originalDebugPrint = debugPrint;
    _tmp = Directory.systemTemp.createTempSync('diag_log_test_');
  });

  tearDown(() {
    DiagLog.resetForTest();
    debugPrint = _originalDebugPrint;
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发占用，忽略
    }
  });

  group('接管 debugPrint', () {
    test('旧实现照常被回调（含 wrapWidth 语义），日志同时落盘', () async {
      var calls = 0;
      int? seenWidth;
      await _boot(previous: (String? m, {int? wrapWidth}) {
        calls++;
        seenWidth = wrapWidth;
      });

      debugPrint('[player_page] 一条日志', wrapWidth: 80);

      expect(calls, 1, reason: '接管不等于吞掉：控制台那份必须还在');
      expect(seenWidth, 80, reason: 'wrapWidth 要原样传下去');
      DiagLog.flushSync();
      expect(_allLogText(), contains('[player_page] 一条日志'));
    });

    test('install 只包装一次：重复调用不叠套', () async {
      var calls = 0;
      await _boot(previous: (String? m, {int? wrapWidth}) => calls++);
      final wrapped = debugPrint;

      await DiagLog.install();
      expect(debugPrint, same(wrapped), reason: '第二次 install 不许再包一层');

      debugPrint('[x] 只回调一次');
      expect(calls, 1, reason: '叠套的话旧实现会被回调两次');
      expect(
        '[x] 只回调一次'.allMatches(_allLogTextAfterFlush()).length,
        1,
        reason: '也不许写两遍',
      );
    });

    test('install 之后测试再临时替换 debugPrint 仍然可用（练习：不劫持库加载期）',
        () async {
      await _boot();
      final installed = debugPrint;

      // 用例自己换掉 debugPrint 抓日志（playview_api_test / update_service_test
      // 的既有写法）—— 必须照旧能抓到，且不再落盘
      final captured = <String>[];
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) captured.add(m);
      };
      debugPrint('[x] 被用例抓走');
      debugPrint = installed;
      expect(captured, ['[x] 被用例抓走']);

      // 换回来以后接管仍然有效
      debugPrint('[x] 恢复后仍在接管');
      DiagLog.flushSync();
      final text = _allLogText();
      expect(text, contains('恢复后仍在接管'));
      expect(text, isNot(contains('被用例抓走')), reason: '被替换期间不落盘');
    });

    test('enabled=false：只回调旧实现，不写盘', () async {
      await _boot(previous: (String? m, {int? wrapWidth}) {});
      DiagLog.enabled = false;
      debugPrint('[x] 不该落盘');
      DiagLog.flushSync();
      expect(_allLogText(), isNot(contains('不该落盘')));
    });
  });

  group('落盘', () {
    test('rootDirOverride 生效：文件落在注入目录的 logs/ 下', () async {
      await _boot();
      debugPrint('[t] 注入目录');
      DiagLog.flushSync();

      final path = DiagLog.logFilePath();
      expect(path, isNotNull);
      expect(path!, startsWith('${_tmp.path}/logs'));
      expect(File(path).readAsStringSync(), contains('注入目录'));
    });

    test('落盘内容已脱敏（SESSDATA / 手机号 / 签名 URL 全部打码）', () async {
      await _boot();
      debugPrint('[bili_api] cookie SESSDATA=secret123 手机 13812345678 '
          'url=https://a.com/x.json?sign=SIGVALUE&deadline=1730000000');
      DiagLog.flushSync();

      final text = _allLogText();
      expect(text, isNot(contains('secret123')));
      expect(text, isNot(contains('13812345678')));
      expect(text, isNot(contains('SIGVALUE')));
      expect(text, contains('SESSDATA=<已脱敏>'));
      expect(text, contains('a.com/x.json'));
    });

    test('tag + 时间前缀：每行都能看出是谁打的、什么时候', () async {
      await _boot();
      debugPrint('[bili_api] 请求失败');
      DiagLog.flushSync();
      final line = _allLogText().trim();
      expect(line, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[bili_api\] 请求失败$')));
    });

    test('单条超长（stack trace 顶进来）截断，不吃掉整个 512KB', () async {
      await _boot();
      debugPrint('[crash] ${'A' * (DiagLog.maxLineLength + 500)}');
      DiagLog.flushSync();
      final text = _allLogText();
      expect(text, contains('…（已截断）'));
      expect(text.length, lessThan(DiagLog.maxLineLength + 200));
    });
  });

  group('去重限流', () {
    test('同 tag 同前缀 1 秒内只写 1 条并计数', () async {
      await _boot();
      for (var i = 0; i < 5; i++) {
        debugPrint('[player] 缓冲中 buffer=0');
      }
      // 来一条不同的日志：重复次数作为一行标记补在它前面
      debugPrint('[player] 缓冲结束');
      DiagLog.flushSync();

      final text = _allLogText();
      expect('[player] 缓冲中 buffer=0'.allMatches(text).length, 1);
      expect(text, contains('重复 4 次'), reason: '被压掉的条数要留痕');
    });

    test('不同 tag 的同样文本不互相压制（tag 参与去重键）', () async {
      await _boot();
      debugPrint('[player] 同样的文本');
      debugPrint('[inbox] 同样的文本');
      DiagLog.flushSync();
      final text = _allLogText();
      expect(text, contains('[player] 同样的文本'));
      expect(text, contains('[inbox] 同样的文本'));
    });

    test('没有 [tag] 前缀的消息按 app 归类（不抛、正常落盘）', () async {
      await _boot();
      debugPrint('裸消息没有 tag');
      debugPrint('裸消息没有 tag');
      DiagLog.flushSync();
      expect('裸消息没有 tag'.allMatches(_allLogText()).length, 1);
    });
  });

  group('轮转与容量', () {
    test('单文件超过 512KB → 换文件；目录里最多 4 份', () async {
      await _boot();
      final payload = 'x' * 2000;
      // 约 2.6MB：必然触发多次轮转，也必然触发"最多 4 份"的裁剪
      for (var i = 0; i < 1300; i++) {
        debugPrint('[bulk] $i $payload');
      }
      DiagLog.flushSync();

      final files = _logFiles();
      expect(files.length, greaterThan(1), reason: '至少轮转过一次');
      expect(files.length, lessThanOrEqualTo(DiagLog.maxFiles));
      expect(
        files.where((f) => f.path.contains('.1.log')).isNotEmpty,
        isTrue,
        reason: '轮转产物按 diag-YYYYMMDD.N.log 命名',
      );
      // 单文件不会失控（一批 flush 最多 ~64×2000 字节压进来）
      for (final f in files) {
        expect(f.lengthSync(), lessThan(DiagLog.maxFileBytes + 200 * 1024));
      }
    });

    test('目录总量超过 5MB → 删最旧，当前活跃文件永不删', () async {
      await _boot();
      _logsDir.createSync(recursive: true);
      // 造三份"以前"的 2MB 日志（合计 6MB），按修改时间从旧到新
      final fakes = <File>[];
      for (var i = 0; i < 3; i++) {
        final f = File('${_logsDir.path}/diag-2020010${i + 1}.log')
          ..writeAsStringSync('a' * (2 * 1024 * 1024));
        f.setLastModifiedSync(DateTime(2020, 1, i + 1));
        fakes.add(f);
      }

      debugPrint('[t] 触发一次 flush，顺手清目录');
      DiagLog.flushSync();

      var total = 0;
      for (final f in _logFiles()) {
        total += f.lengthSync();
      }
      expect(total, lessThanOrEqualTo(DiagLog.maxDirBytes));
      expect(fakes.first.existsSync(), isFalse, reason: '最旧的那份被删');
      expect(File(DiagLog.logFilePath()!).existsSync(), isTrue,
          reason: '正在写的文件不许删');
    });
  });

  group('崩溃路径', () {
    test('recordError + flushSync：文件里立刻能读到异常与堆栈', () async {
      await _boot();
      DiagLog.recordError(
        'zone',
        StateError('异步炸了'),
        stack: StackTrace.fromString('#0      foo (package:x/a.dart:1:1)'),
      );

      final path = DiagLog.logFilePath();
      expect(path, isNotNull);
      final text = File(path!).readAsStringSync();
      expect(text, contains('[crash:zone]'));
      expect(text, contains('异步炸了'));
      expect(text, contains('a.dart:1:1'));
    });

    test('崩溃记录同样过脱敏（异常文本里带凭据也不许漏）', () async {
      await _boot();
      DiagLog.recordError('engine', Exception('SESSDATA=leakme'));
      expect(File(DiagLog.logFilePath()!).readAsStringSync(),
          isNot(contains('leakme')));
    });
  });

  group('失败静默', () {
    test('根目录不可用：write / flushSync / exportBundle 都不抛', () async {
      final bogus = File('${_tmp.path}/not_a_dir')..writeAsStringSync('x');
      DiagLog.resetForTest();
      DiagLog.rootDirOverride = Directory(bogus.path);
      debugPrint = _silent;
      await DiagLog.install();

      expect(() => debugPrint('[x] 写不进去'), returnsNormally);
      expect(() => DiagLog.flushSync(), returnsNormally);
      expect(await DiagLog.exportBundle(), isNull);
      expect(() => DiagLog.recordError('zone', '也不许抛'), returnsNormally);
    });

    test('没有日志文件时 exportBundle → null（不造空包）', () async {
      await _boot();
      expect(await DiagLog.exportBundle(), isNull);
    });
  });

  group('导出', () {
    test('zip 里包含日志文件 + meta.txt（版本 / 条数 / 脱敏说明）', () async {
      await _boot();
      debugPrint('[t] 第一条');
      debugPrint('[t] 第二条');
      DiagLog.flushSync();

      final path = await DiagLog.exportBundle();
      expect(path, isNotNull);
      final zip = File(path!);
      expect(zip.existsSync(), isTrue);
      expect(zip.path, endsWith('.zip'));

      final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
      final names = archive.files.map((f) => f.name).toList();
      expect(names, contains('meta.txt'));
      expect(
        names.any((n) => n.startsWith('diag-') && n.endsWith('.log')),
        isTrue,
      );

      final metaFile = archive.files.firstWhere((f) => f.name == 'meta.txt');
      final meta = utf8.decode(metaFile.content as List<int>);
      expect(meta, contains('App 版本'));
      expect(meta, contains('日志条数'));
      expect(meta, contains('已自动脱敏'));
      expect(meta, contains('系统'), reason: '机型 / Android 版本要带上');
    });

    test('导出目录最多留 3 个包（连点几次不涨存储）', () async {
      await _boot();
      debugPrint('[t] 一条');
      DiagLog.flushSync();
      for (var i = 0; i < 5; i++) {
        await DiagLog.exportBundle();
      }
      final exportDir = Directory('${_logsDir.path}/export');
      final zips = exportDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList();
      expect(zips.length, lessThanOrEqualTo(3));
    });
  });

  group('原生崩溃碎片', () {
    test('native-crash-*.txt 合入 diag 日志后删掉原文件', () async {
      await _boot();
      _logsDir.createSync(recursive: true);
      final fragment = File('${_logsDir.path}/native-crash-1730000000000.txt')
        ..writeAsStringSync('time: x\nthread: main\njava.lang.NullPointerException\n');

      final merged = await DiagLog.mergeNativeCrashes();
      expect(merged, 1);
      expect(fragment.existsSync(), isFalse);

      final text = _allLogText();
      expect(text, contains('[crash:native]'));
      expect(text, contains('NullPointerException'));
    });
  });

  group('内存最近日志', () {
    test('recentLines(n) 只给最后 n 条', () async {
      await _boot();
      for (var i = 0; i < 5; i++) {
        debugPrint('[recent] 第 $i 条');
      }
      final lines = DiagLog.recentLines(2);
      expect(lines.length, 2);
      expect(lines.last, contains('第 4 条'));
      expect(lines.first, contains('第 3 条'));
      expect(DiagLog.recentLines(0), isEmpty);
    });
  });
}

/// 先 flush 再取全文（上面个别断言要"读的时候已经落盘"）。
String _allLogTextAfterFlush() {
  DiagLog.flushSync();
  return _allLogText();
}
