// 日志脱敏（v2.67.0）：`utils/log_redact.dart` 的逐条契约。
//
// 这一层是"日志落盘"能不能给用户看的**唯一闸门**，所以两类行为都要钉死：
//
// 1. **老行为逐字不变**（v2.46.0 在 update_service 里定下的，老单测在
//    `test/update_service_test.dart` 里还留着）：
//    `maskUrlForLog` 只留 host+path、`'' → '(空 URL)'`、非绝对 URL →
//    `'<非绝对 URL，已省略>'`、`null → '—'`；
// 2. **v2.67.0 扩的表**：B 站登录态（SESSDATA / bili_jct / csrf /
//    access_key / access_token / refresh_token / bili_ticket）、接口签名
//    （deadline / sign / X-Amz-Signature）、Authorization 头、11 位手机号、
//    JSON / 冒号形态的具名凭据、搜索词（keyword / key_word）—— 值必须消失，
//    键名必须留下。
//
// 另外还要钉住"不误伤"：`design=` 之类含 sign 字样的普通参数、13 位时间戳、
// bvid 里的数字都不许被抹掉（脱敏过度会让日志失去排查价值，这是另一种失败）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/log_redact.dart';

void main() {
  group('maskUrlForLog：老行为逐字不变', () {
    test('只留 host + path —— query 里的签名参数绝不出现', () {
      expect(
        maskUrlForLog('https://objects.githubusercontent.com/a/b.apk'
            '?X-Amz-Signature=SECRET&X-Amz-Credential=KEY'),
        'objects.githubusercontent.com/a/b.apk',
      );
      expect(
        maskUrlForLog('https://aisubtitle.hdslb.com/bfs/subtitle/x.json'
            '?deadline=1730000000&sign=abcdef'),
        'aisubtitle.hdslb.com/bfs/subtitle/x.json',
        reason: 'host + path 原样拼回，query 整条丢掉',
      );
    });

    test('空串 / 非绝对 URL / 首尾空白', () {
      expect(maskUrlForLog(''), '(空 URL)');
      expect(maskUrlForLog('   '), '(空 URL)');
      expect(maskUrlForLog('gist.github.com'), '<非绝对 URL，已省略>');
      expect(maskUrlForLog('  https://a.com/b?c=1  '), 'a.com/b');
    });
  });

  group('sanitizeLogText：老行为逐字不变', () {
    test('URL 截成 host+path、Bearer 与裸 gh token 换成占位符', () {
      final token = 'ghp_${'A' * 24}';
      final text = sanitizeLogText(
          'DioException uri=https://cdn.example.com/x.apk?sig=SECRET '
          'header=Bearer $token');
      expect(text, contains('cdn.example.com/x.apk'));
      expect(text, isNot(contains('SECRET')));
      expect(text, isNot(contains(token)));
      expect(text, isNot(contains('ghp_')));
      expect(text, contains('Bearer <已脱敏>'));
    });

    test('没有 Bearer 前缀的裸 token 也要换（老单测的逐字断言）', () {
      final token = 'ghp_${'A' * 24}';
      expect(sanitizeLogText('token=$token 无效'), 'token=<token 已脱敏> 无效');
    });

    test('null → 占位符（不是字符串 "null"）', () {
      expect(sanitizeLogText(null), '—');
    });
  });

  group('sanitizeLogText：v2.67.0 扩表', () {
    test('B 站登录态 / CSRF / access_key / refresh_token 打码（键名留下）', () {
      final text = sanitizeLogText(
        'cookie: SESSDATA=abc123%2Cdef; bili_jct=csrf_value_1; '
        'csrf=csrf_value_2 body access_key=ak_9 refresh_token=rt_7',
      );
      for (final leaked in [
        'abc123%2Cdef',
        'csrf_value_1',
        'csrf_value_2',
        'ak_9',
        'rt_7',
      ]) {
        expect(text, isNot(contains(leaked)), reason: '$leaked 不许留在日志里');
      }
      expect(text, contains('SESSDATA=<已脱敏>'));
      expect(text, contains('bili_jct=<已脱敏>'));
      expect(text, contains('csrf=<已脱敏>'));
      expect(text, contains('access_key=<已脱敏>'));
      expect(text, contains('refresh_token=<已脱敏>'));
    });

    test('接口签名 / 对象存储签名打码', () {
      final text = sanitizeLogText(
        'deadline=1730000000 sign=abcdef0123 '
        'X-Amz-Signature=SECRETSIG',
      );
      expect(text, contains('deadline=<已脱敏>'));
      expect(text, contains('sign=<已脱敏>'));
      expect(text, contains('X-Amz-Signature=<已脱敏>'));
      expect(text, isNot(contains('1730000000')));
      expect(text, isNot(contains('abcdef0123')));
      expect(text, isNot(contains('SECRETSIG')));
    });

    test('X-Amz-Signature 不会被 sign 规则吃掉一半（键名原样保留）', () {
      final text = sanitizeLogText('X-Amz-Signature=abc');
      expect(text, 'X-Amz-Signature=<已脱敏>');
    });

    test('Authorization 头（含 Bearer）整段打码，token 不残留', () {
      expect(
        sanitizeLogText('Authorization: Bearer abc.def.ghi'),
        'Authorization: <已脱敏>',
      );
      expect(
        sanitizeLogText('authorization: Basic dXNlcjpwYXNz'),
        'authorization: <已脱敏>',
      );    });

    test('11 位手机号打码', () {
      final text = sanitizeLogText('用户 13812345678 报障：播放失败');
      expect(text, contains('<手机号已脱敏>'));
      expect(text, isNot(contains('13812345678')));
      expect(text, contains('报障'));
    });

    test('JSON / 冒号形态：分隔符与引号原样保留，值打码', () {
      final text = sanitizeLogText(
        '{"SESSDATA":"json_sess","bili_ticket":"ticket_1",'
        '"access_token":"at_2"} refresh_token: rt_json',
      );
      for (final leaked in ['json_sess', 'ticket_1', 'at_2', 'rt_json']) {
        expect(text, isNot(contains(leaked)), reason: '$leaked 不许留在日志里');
      }
      expect(text, contains('"SESSDATA":"<已脱敏>"'));
      expect(text, contains('"bili_ticket":"<已脱敏>"'));
      expect(text, contains('"access_token":"<已脱敏>"'));
      expect(text, contains('refresh_token: <已脱敏>'));
    });

    test('搜索词打码：值消失，后面的分页参数必须留下', () {
      final text = sanitizeLogText('[bili_api] searchLive keyword=原神 攻略 page=2');
      expect(text, isNot(contains('原神')));
      expect(text, isNot(contains('攻略')));
      expect(text, contains('keyword=<已脱敏>'));
      expect(text, contains('page=2'), reason: '分页参数是排查用的，不许被吃掉');
    });

    test('搜索词：key_word 与冒号形态也认', () {
      expect(
        sanitizeLogText('search key_word: 某个词 隐藏关键字'),
        'search key_word: <已脱敏>',
      );
    });
  });

  group('sanitizeLogText：不误伤（脱敏过度也是 bug）', () {
    test('含 sign 字样的普通参数不动（design / signature 之外的形态）', () {
      const raw = 'design=modern assigned=1';
      expect(sanitizeLogText(raw), raw);
    });

    test('13 位时间戳 / bvid / 10 位数字不动', () {
      const raw = 'ts=1730000000000 bvid=BV1xx411c7mD cid=137649199';
      expect(sanitizeLogText(raw), raw);
    });

    test('URL 里的路径参数不被当成凭据（整条 query 已经先丢了）', () {
      final text = sanitizeLogText('https://a.com/p?sign=1&deadline=2');
      expect(text, 'a.com/p');
    });
  });
}
