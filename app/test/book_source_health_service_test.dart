// 书源可用性检测测试（F2）。
//
// 这里钉的是「一个源到底会得到什么状态」以及「批量检测不会把自己打爆」：
// 1. 六种状态各一例（用假引擎造出对应的页面 / 异常，不联网）；
// 2. `probeAll` 的并发上限、取消、进度；
// 3. 落盘（单 key）与 200 条裁剪、坏数据不崩；
// 4. 纯函数 `classifyGroup` / `summarizeSearchFailures` 的归类口径。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_search_service.dart';
import 'package:bili_whitelist_app/services/book_source_health_service.dart';

BookSource _src(
  String name, {
  String list = '.item',
  String nameRule = '.title',
  String detailUrl = 'a@href',
  String url = '/search?q={{key}}',
  bool enabled = true,
}) =>
    BookSource(
      name: name,
      baseUrl: 'https://$name.example',
      enabled: enabled,
      search: SearchRule(
        url: url,
        list: list,
        name: nameRule,
        detailUrl: detailUrl,
      ),
      toc: const TocRule(),
      content: const ContentRule(text: '#content'),
    );

/// 一个总能搜到一条结果的引擎。
FakeRuleEngine _okEngine() => FakeRuleEngine(
      onFetch: (url) async => '<html><body>ok</body></html>',
      onQueryMap: (html, list, fields) async => {
        'name': ['斗罗大陆'],
        'detailUrl': ['https://book.example/1'],
      },
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('单源探测：六种状态', () {
    test('ok：有结果，count = 命中条数', () async {
      final service = BookSourceHealthService(engine: _okEngine());
      final health = await service.probe(_src('ok源'));

      expect(health.status, SourceHealthStatus.ok);
      expect(health.count, 1);
      expect(health.sourceKey, 'ok源');
      expect(health.label, '可用 1 条');
    });

    test('ok：停用的源也照样能测（用户正是在判断要不要删它）', () async {
      final service = BookSourceHealthService(engine: _okEngine());
      final health = await service.probe(_src('停用源', enabled: false));
      expect(health.status, SourceHealthStatus.ok);
    });

    test('noResult：HTTP 通、页面正常，但列表规则命中 0 条', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          onFetch: (url) async => '<html><body>空空如也</body></html>',
          onQueryMap: (html, list, fields) async => const {},
        ),
      );
      final health = await service.probe(_src('空源'));
      expect(health.status, SourceHealthStatus.noResult);
      expect(health.count, 0);
    });

    test('noResult 后用备选关键词再搜一次（英文源别被误判成坏源）', () async {
      var lastUrl = '';
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          onFetch: (url) async {
            lastUrl = url;
            return '<html></html>';
          },
          onQueryMap: (html, list, fields) async {
            // 只有英文关键词才「搜得到」
            if (!lastUrl.contains(kHealthFallbackKeyword)) return const {};
            return {
              'name': ['Love and Friendship'],
              'detailUrl': ['https://book.example/1'],
            };
          },
        ),
      );
      final health = await service.probe(_src('英文源'));

      expect(health.status, SourceHealthStatus.ok);
      expect(health.count, 1);
      expect(health.message, contains(kHealthFallbackKeyword));
    });

    test('blocked：403 这类状态码算被拦（不是「没结果」）', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          onFetch: (url) async => throw const RuleEngineException(
            RuleErrorKind.network,
            '站点返回 403：https://x.example/search',
            statusCode: 403,
          ),
        ),
      );
      final health = await service.probe(_src('拦源'));
      expect(health.status, SourceHealthStatus.blocked);
      expect(health.message, contains('403'));
    });

    test('blocked：HTTP 200 的验证页也要认出来（不能报成「没结果」）', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          // 搜索那次与复核那次拿到的是同一张验证页
          onFetch: (url) async =>
              '<html><body><p>Checking the security of your connection…</p>'
              '<script src="/turnstile/v0/api.js"></script></body></html>',
          onQueryMap: (html, list, fields) async => const {},
        ),
      );
      final health = await service.probe(_src('挑战源'));
      expect(health.status, SourceHealthStatus.blocked);
      expect(health.message, contains('验证页'));
    });

    test('networkError：连不上 / 超时算网络问题', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          onFetch: (url) async => throw const RuleEngineException(
            RuleErrorKind.network,
            '连不上站点（网络不可用或站点拒绝连接）',
          ),
        ),
      );
      final health = await service.probe(_src('断网源'));
      expect(health.status, SourceHealthStatus.networkError);
    });

    test('networkError：5xx 不是「被拦」', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(
          onFetch: (url) async => throw const RuleEngineException(
            RuleErrorKind.network,
            '站点返回 503：https://x.example',
            statusCode: 503,
          ),
        ),
      );
      final health = await service.probe(_src('维护源'));
      expect(health.status, SourceHealthStatus.networkError);
    });

    test('unsupportedJs：缺本版没有的 JS 能力（变量表）的源不发请求', () async {
      final engine = _okEngine();
      final service = BookSourceHealthService(engine: engine);
      final health = await service.probe(
        _src('js源', nameRule: '<js>java.put("a", "b"); result = "x"</js>'),
      );

      expect(health.status, SourceHealthStatus.unsupportedJs);
      expect(health.message, contains('java.put'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('needsAjax：需要 java.ajax 的源单列一档，也不发请求', () async {
      // v2.78.0 新增：与「需 JS」分开 —— 一个等版本，一个要改源
      final engine = _okEngine();
      final service = BookSourceHealthService(engine: engine);
      final health = await service.probe(
        _src('ajax源', nameRule: '<js>result = java.ajax("/api")</js>'),
      );

      expect(health.status, SourceHealthStatus.needsAjax);
      expect(health.message, contains('java.ajax'));
      expect(health.label, '需 ajax');
      expect(engine.fetchedUrls, isEmpty);
    });

    test('纯静态 JS 的源**真的去探测**（不再判死）', () async {
      // v2.78.0 的设计契约变更：v2.77.0 及以前 `<js>x</js>` 直接判「需 JS」。
      // I3b 起静态 JS 能跑，判死就是白丢一个能搜的源。
      final engine = FakeRuleEngine(
        onFetch: (url) async => '<html><body>ok</body></html>',
        onQueryMap: (html, list, fields) async => {
          // nameRule 是 JS（不在回调里），回调只负责选择器字段
          'detailUrl': ['https://book.example/1'],
        },
        onEvalJs: (script, bindings, base) async => '斗罗大陆',
      );
      final service = BookSourceHealthService(engine: engine);
      final health =
          await service.probe(_src('静态JS源', nameRule: '<js>x</js>'));

      expect(health.status, SourceHealthStatus.ok);
      expect(health.count, 1);
      expect(engine.fetchedUrls, isNotEmpty);
      // 脚本真的被送进沙箱
      expect(engine.jsRuleScripts, ['x']);
    });

    test('badRule：规则本身拼不出来（没配列表规则）', () async {
      final service = BookSourceHealthService(engine: _okEngine());
      final health = await service.probe(_src('坏规则源', list: ''));
      expect(health.status, SourceHealthStatus.badRule);
    });

    test('坏规则源也不抛异常（最差就是一条状态）', () async {
      final service = BookSourceHealthService(
        engine: FakeRuleEngine(onFetch: (url) async {
          throw StateError('引擎炸了');
        }),
      );
      final health = await service.probe(_src('炸源'));
      expect(health.status, SourceHealthStatus.networkError);
    });
  });

  group('probeAll', () {
    test('并发不超过 2，进度按 1..N 递增', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 8));
          inFlight--;
          return '<html></html>';
        },
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['https://book.example/1'],
        },
      );
      final service = BookSourceHealthService(engine: engine);
      final sources = [for (var i = 1; i <= 5; i++) _src('源$i')];
      final progress = <int>[];

      final results = await service.probeAll(
        sources,
        onProgress: (done, total) {
          expect(total, 5);
          progress.add(done);
        },
      );

      expect(results.length, 5);
      expect(maxInFlight, kHealthProbeConcurrency);
      expect(progress, [1, 2, 3, 4, 5]);
    });

    test('可取消：取消后不再开新活，只返回已完成的那些', () async {
      var done = 0;
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return '<html></html>';
        },
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['https://book.example/1'],
        },
      );
      final service = BookSourceHealthService(engine: engine);
      final sources = [for (var i = 1; i <= 10; i++) _src('源$i')];

      final results = await service.probeAll(
        sources,
        onProgress: (d, _) => done = d,
        isCancelled: () => done >= 2,
      );

      expect(results.length, lessThan(sources.length));
      expect(results.length, greaterThanOrEqualTo(2));
      expect(done, lessThan(10));
    });

    test('空列表直接返回空（不建引擎、不打网络）', () async {
      final engine = _okEngine();
      final service = BookSourceHealthService(engine: engine);
      expect(await service.probeAll(const []), isEmpty);
      expect(engine.fetchedUrls, isEmpty);
    });
  });

  group('存储', () {
    test('结果落在单 key 上，能被新实例读回', () async {
      final service = BookSourceHealthService(engine: _okEngine());
      await service.probe(_src('落盘源'));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kSourceHealthStorageKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded.keys, ['落盘源']);
      expect(decoded['落盘源']['status'], 'ok');
      expect(decoded['落盘源']['count'], 1);

      // 新实例（模拟重启）从 prefs 读回同样的结果
      final fresh = BookSourceHealthService(engine: _okEngine());
      final all = await fresh.loadAll();
      expect(all['落盘源']?.status, SourceHealthStatus.ok);
      expect(await fresh.getHealth('落盘源'), isNotNull);
      // 源名大小写不敏感
      expect(await fresh.getHealth('  落盘源 '), isNotNull);
    });

    test('最多保留 200 个源（超出按时间裁最旧）', () async {
      final prefs = await SharedPreferences.getInstance();
      // 预置 205 条很旧的结果
      final seed = <String, dynamic>{
        for (var i = 0; i < 205; i++)
          'old$i': SourceHealth(
            sourceKey: 'old$i',
            status: SourceHealthStatus.ok,
            at: DateTime(2020, 1, 1).add(Duration(minutes: i)),
            count: 1,
          ).toJson(),
      };
      await prefs.setString(kSourceHealthStorageKey, jsonEncode(seed));

      final service = BookSourceHealthService(engine: _okEngine());
      await service.probe(_src('新源'));

      final all = await service.loadAll();
      expect(all.length, kSourceHealthMaxEntries);
      expect(all.containsKey('新源'), isTrue);
      // 最旧的那条被裁掉了
      expect(all.containsKey('old0'), isFalse);
    });

    test('坏数据不崩：不是 JSON / 状态名不认识 / 不是对象', () async {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(kSourceHealthStorageKey, '这不是 JSON');
      expect(
        await BookSourceHealthService(engine: _okEngine()).loadAll(),
        isEmpty,
      );

      await prefs.setString(
        kSourceHealthStorageKey,
        jsonEncode({
          '甲': {'status': '没这个状态'},
          '乙': '不是对象',
          '丙': {'status': 'ok', 'at': 123, 'count': 'x'},
        }),
      );
      final all =
          await BookSourceHealthService(engine: _okEngine()).loadAll();
      expect(all.keys, ['丙']);
      expect(all['丙']!.count, 0); // 坏 count 当 0，不抛
    });

    test('clear 之后读回空表', () async {
      final service = BookSourceHealthService(engine: _okEngine());
      await service.probe(_src('要清的'));
      expect(await service.loadAll(), isNotEmpty);

      expect(await service.clear(), isTrue);
      expect(await service.loadAll(), isEmpty);
    });
  });

  group('归类纯函数', () {
    test('classifyGroup：状态码优先于其它判据', () {
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.error,
          httpStatus: 429,
          errorKind: RuleErrorKind.network,
        )),
        SourceHealthStatus.blocked,
      );
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.error,
          httpStatus: 500,
        )),
        SourceHealthStatus.networkError,
      );
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.error,
          errorKind: RuleErrorKind.timeout,
        )),
        SourceHealthStatus.networkError,
      );
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.error,
          errorKind: RuleErrorKind.empty,
        )),
        SourceHealthStatus.noResult,
      );
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.unsupported,
        )),
        SourceHealthStatus.badRule,
      );
      // v2.78.0：判死原因是「要发网络请求」时单列 needsAjax（不是规则坏）
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.unsupported,
          needsAjax: true,
        )),
        SourceHealthStatus.needsAjax,
      );
      expect(
        classifyGroup(const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.noResult,
        )),
        SourceHealthStatus.noResult,
      );
    });

    test('summarizeSearchFailures：按「被拦 → 连不上 → 规则坏」归类汇总', () {
      final summary = summarizeSearchFailures([
        const BookSearchGroup(
          sourceName: 'a',
          status: BookSearchStatus.error,
          httpStatus: 403,
        ),
        const BookSearchGroup(
          sourceName: 'b',
          status: BookSearchStatus.error,
          errorKind: RuleErrorKind.timeout,
        ),
        const BookSearchGroup(
          sourceName: 'c',
          status: BookSearchStatus.unsupported,
        ),
        // 正常返回 0 条的源不算失败
        const BookSearchGroup(
          sourceName: 'd',
          status: BookSearchStatus.noResult,
        ),
      ]);
      expect(summary, '1 个源被拦、1 个源连不上、1 个源规则有问题');
    });

    test('summarizeSearchFailures：没有失败时返回空串', () {
      expect(
        summarizeSearchFailures(const [
          BookSearchGroup(sourceName: 'a', status: BookSearchStatus.noResult),
        ]),
        isEmpty,
      );
    });
  });
}
