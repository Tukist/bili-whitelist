// 掌厅解析 / 判定 / 轮询策略单测（v2.54.0）。
//
// 覆盖路线 C（接口响应：密文/明文判定 → 解密 → 字段映射 → unit 换算）与
// 路线 B（页面文字正则）、页面分类、会话失效判定、手机号脱敏、轮询退避策略、
// 以及"点页面文案"的白名单/黑名单（**绝不自动重发验证码**那条红线的落点）。
//
// 断言目标都是**可观测的值**（数字、字符串、布尔），不是"没抛异常"。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/cmcc_page.dart';
import 'package:bili_whitelist_app/services/cmcc_hook_script.dart';
import 'package:bili_whitelist_app/services/cmcc_plan.dart';
import 'package:bili_whitelist_app/services/cmcc_poll_policy.dart';

/// 一份明文形态的余量 JSON（字段照调研给的形态；数字是编的）。
const String _plainMargin =
    '{"code":"0000","data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
    '{"usedNum":"6.05","remainNum":"73.95","sumNum":"80","unit":"04"},'
    '"directionalFlowInfo":{"usedNum":"3.22","remainNum":"26.78","sumNum":"30","unit":"04"},'
    '"otherRemian":{"usedNum":"0","remainNum":"0","sumNum":"0","unit":"04"},'
    '"totalInfo":{"usedNum":"9.27","remainNum":"100.73","sumNum":"110","unit":"04"}}}}}';

/// 同一份 JSON 的密文（自造向量，key/IV 就是掌厅网页里那两个常量）。
const String _cipherMargin =
    '1567779d8f74e2926e1b2eb3ae12c34f5bfa5477999858bd85f28f1c716da40fa952828348c7ae11550873dd8dc0eaf4ba9b7af8ac7299579f3ce25fd9bf9497ab4255dcec20cf2dd58d4bc4d93bbdf63bb3dc7cca0cc2bf4db070546d3404c2d51061128146fb993dc3bf0daff54ebaabdec0d1a011d8fad19fd01caea78bf22f7aefb11a042b7065eee5b742bd291e9748c07ddd20ee7bde45d6ea516b12208cb3ff1f6b4e2fad5885fe055eaa9c89e304ddb800ac8d9f15d1b7afa46701d4baaeaadeedab5ff0c81fc147eb6ca1d19e162472b74e757acfcd98db5e57e157e339a1f359a9208b6d52e2d966dd2f061f2b1c5aaa5efc70e72ed0a04935a0605e5f8e3636eff0356472852d5fef748dc7d362cab8415875b393b1821adfb939952f924099f809f4b8be61d96bb311dcf0d7771f19f9519cebea74c2135d34f8ccf0bf13a6943a4dc2cf60d7ed14c96b8ee5183d16be0d1be1a896d7580b12ceabdc569011443d2adba13050866db4292b8d869c634bd1528228982e3dbebbb8';

void main() {
  group('① C 路线：判定密文/明文 + 解密', () {
    test('明文 JSON：原样用，不动', () {
      expect(decryptCmccPayload(_plainMargin), _plainMargin);
      expect(decryptCmccPayload('  $_plainMargin  '), _plainMargin,
          reason: '前后空白要先 trim');
    });

    test('hex 密文：解出明文 JSON', () {
      final plain = decryptCmccPayload(_cipherMargin);
      expect(plain, _plainMargin);
      expect(jsonDecode(plain), isA<Map<String, Object?>>());
    });

    test('解不开的 hex → 抛（不把垃圾当数据）', () {
      expect(() => decryptCmccPayload('0' * 32), throwsA(isA<FormatException>()));
    });

    test('候选串：明文 body 本身 + 顶层 JSON 里的字符串值', () {
      expect(cmccPayloadCandidates('plain'), ['plain']);
      expect(cmccPayloadCandidates('{"data":"$_cipherMargin"}'),
          ['{"data":"$_cipherMargin"}', _cipherMargin]);
      expect(cmccPayloadCandidates('{"a":1,"b":""}'), ['{"a":1,"b":""}'],
          reason: '数字值与空串都不当候选（只挑非空字符串）');
    });
  });

  group('② C 路线：字段映射（真实样例形态）', () {
    test('密文响应：通用 6.05/80、定向 3.22/30、总 9.27/110', () {
      final r = parsePlanBody(_cipherMargin);
      expect(r.isOk, isTrue);
      final reading = r.reading!;
      expect(reading.source, CmccReadingSource.api);
      expect(reading.generalUsedGb, closeTo(6.05, 1e-9));
      expect(reading.general.remainGb, closeTo(73.95, 1e-9));
      expect(reading.general.totalGb, closeTo(80, 1e-9));
      expect(reading.general.unitRaw, '04');
      expect(reading.general.unitLabel, 'GB');
      expect(reading.directional!.usedGb, closeTo(3.22, 1e-9));
      expect(reading.directional!.totalGb, closeTo(30, 1e-9));
      expect(reading.total!.usedGb, closeTo(9.27, 1e-9));
      // 其他/区域是 0/0/0 → 按"没给读数"处理（不是 0）
      expect(reading.other, isNull, reason: '全 0 等于没给读数，不许显示 0');
    });

    test('明文响应同样解得出（有的分支直出 JSON）', () {
      final r = parsePlanBody(_plainMargin);
      expect(r.isOk, isTrue);
      expect(r.reading!.generalUsedGb, closeTo(6.05, 1e-9));
      expect(r.reading!.directional!.usedGb, closeTo(3.22, 1e-9));
    });

    test('外面包了一层 {"data":"<hex>"} 也认', () {
      final r = parsePlanBody('{"code":"0000","data":"$_cipherMargin"}');
      expect(r.isOk, isTrue);
      expect(r.reading!.generalUsedGb, closeTo(6.05, 1e-9));
    });

    test('数值/单位容错：数字型、带单位后缀、单位写成 4', () {
      const body = '{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":6.05,"remainNum":"73.95GB","sumNum":80,"unit":4}}}}';
      final r = parsePlanBody(body);
      expect(r.isOk, isTrue);
      expect(r.reading!.general.unitRaw, '04');
      expect(r.reading!.general.usedGb, closeTo(6.05, 1e-9));
    });

    test('缺字段 / 结构不对 → 失败并给出可读原因', () {
      expect(parsePlanBody('').error, kCmccFailNoResponse);
      expect(parsePlanBody('   ').error, kCmccFailNoResponse);
      expect(parsePlanBody('不是 json 也不是 hex').error, isNotNull);
      // 解不开的 hex → 明确说"解不开"，而不是"字段缺失"
      expect(parsePlanBody('0' * 32).error, kCmccFailDecrypt);
      // 能 parse 但没有通用流量字段 → 说"字段缺失"
      expect(parsePlanBody('{"data":{"resultData":{}}}').error,
          kCmccFailNoGeneral);
      expect(
          parsePlanBody(
                  '{"data":{"resultData":{"planRemianFlowInfo":{}}}}')
              .error,
          kCmccFailNoGeneral);
    });

    test('通用流量单位不是流量（01/02）→ 不认，并说清是单位的问题（不瞎换算）', () {
      const body = '{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"30","sumNum":"100","unit":"01"}}}}';
      final r = parsePlanBody(body);
      expect(r.isOk, isFalse, reason: '分钟不是流量，不能当 GB 用');
      expect(r.error, kCmccFailUnknownUnit);
      // 单位码认不出的情况同样归到"单位的问题"
      const weird = '{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"30","sumNum":"100","unit":"77"}}}}';
      expect(parsePlanBody(weird).error, kCmccFailUnknownUnit);
    });
  });

  group('③ unit 码换算（01/02/03/04）', () {
    test('04=GB 原值；03=MB 除 1024', () {
      expect(cmccToGb(6.05, '04'), closeTo(6.05, 1e-9));
      expect(cmccToGb(2048, '03'), closeTo(2.0, 1e-9));
      expect(cmccToGb(1024, '03'), closeTo(1.0, 1e-9));
      expect(cmccToGb(0, '04'), 0);
    });

    test('01=分钟 / 02=条 / 未知码 / null → null（不是流量就不换算）', () {
      expect(cmccToGb(30, '01'), isNull);
      expect(cmccToGb(10, '02'), isNull);
      expect(cmccToGb(10, '07'), isNull);
      expect(cmccToGb(10, null), isNull);
      expect(cmccToGb(null, '04'), isNull);
      expect(kCmccUnitLabels['01'], '分钟');
      expect(kCmccUnitLabels['02'], '条');
      expect(kCmccUnitLabels['03'], 'MB');
      expect(kCmccUnitLabels['04'], 'GB');
    });

    test('MB 单位的响应：2048MB → 2.00 GB', () {
      const body = '{"data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"2048","remainNum":"0","sumNum":"4096","unit":"03"}}}}}';
      final r = parsePlanBody(body);
      expect(r.isOk, isTrue);
      expect(r.reading!.generalUsedGb, closeTo(2.0, 1e-9));
      expect(r.reading!.general.totalGb, closeTo(4.0, 1e-9));
    });

    test('缺 sumNum（只给已用/剩余）也能用：总量如实为 null', () {
      const body = '{"data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"6.05","remainNum":"73.95","unit":"04"}}}}}';
      final r = parsePlanBody(body);
      expect(r.isOk, isTrue);
      expect(r.reading!.general.usedGb, closeTo(6.05, 1e-9));
      expect(r.reading!.general.totalGb, isNull, reason: '没给总量就别编一个');
      expect(r.reading!.directional, isNull);
      expect(r.reading!.total, isNull);
    });

    test('CmccQuota.isBlank：全 0 / 没数 → 没给读数；有一个非 0 就算给了', () {
      expect(const CmccQuota(used: 0, remain: 0, total: 0, unitRaw: '04').isBlank,
          isTrue);
      expect(const CmccQuota(unitRaw: '04').isBlank, isTrue);
      expect(const CmccQuota(used: 0, remain: 1, total: 0, unitRaw: '04').isBlank,
          isFalse);
      expect(const CmccQuota(used: 3.22, unitRaw: '04').isBlank, isFalse);
    });

    test('"已用 0 + 总量 80"是真的 0（新月没用），不是"没给读数"', () {
      const body = '{"data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"0","remainNum":"80","sumNum":"80","unit":"04"}}}}}';
      final r = parsePlanBody(body);
      expect(r.isOk, isTrue, reason: '有总量兜着，说明这个节点是真给了读数');
      expect(r.reading!.generalUsedGb, 0.0);
      expect(r.reading!.general.usedGb, isNotNull,
          reason: '0 与 null 在界面上是两句话，不能混');
    });
  });

  group('④ B 路线：页面文字正则', () {
    test('认出通用 / 定向（带 GB）', () {
      const text = '中国移动 我的 通用流量 已用 6.05GB 剩余 73.95GB '
          '定向流量 已用 3.22GB 剩余 26.78GB';
      final r = parsePageText(text);
      expect(r.isOk, isTrue);
      expect(r.reading!.source, CmccReadingSource.pageText);
      expect(r.reading!.generalUsedGb, closeTo(6.05, 1e-9));
      expect(r.reading!.general.remainGb, closeTo(73.95, 1e-9));
      expect(r.reading!.directional!.usedGb, closeTo(3.22, 1e-9));
      expect(r.reading!.total, isNull, reason: '页面没写总流量就别编');
    });

    test('只给「总量 + 剩余」→ 相减推算已用', () {
      const text = '通用流量 总量 80GB 剩余 73.95GB';
      final r = parsePageText(text);
      expect(r.isOk, isTrue);
      expect(r.reading!.generalUsedGb, closeTo(6.05, 1e-9));
    });

    test('MB 单位也换算', () {
      const text = '通用流量 已用 2048MB 剩余 0MB';
      final r = parsePageText(text);
      expect(r.isOk, isTrue);
      expect(r.reading!.generalUsedGb, closeTo(2.0, 1e-9));
    });

    test('定向写 0（或没有）→ 定向为 null，**不是 0**', () {
      const zero = '通用流量 已用 6.05GB 定向流量 已用 0GB 剩余 0GB';
      final r0 = parsePageText(zero);
      expect(r0.isOk, isTrue);
      expect(r0.reading!.directional, isNull,
          reason: '全 0 就是"掌厅没给定向读数"，界面要如实说，不许显示 0');

      const noDir = '通用流量 已用 6.05GB 剩余 73.95GB';
      final r1 = parsePageText(noDir);
      expect(r1.isOk, isTrue);
      expect(r1.reading!.directional, isNull);
    });

    test('认不出就给可读原因（不猜裸数字）', () {
      expect(parsePageText('').error, kCmccFailNoText);
      expect(parsePageText('今天天气不错，流量套餐介绍').error, kCmccFailNoText);
      expect(parsePageText('通用流量 剩余 73.95GB').error, kCmccFailNoText,
          reason: '只有剩余、推不出已用 → 不许瞎猜');
      expect(parsePageText('通用流量 6.05 80').error, kCmccFailNoText,
          reason: '裸数字没有单位，不许当 GB');
    });
  });

  group('⑤ 页面分类（登录页 / 维护中 / 首页 / 不认识）', () {
    test('登录页特征', () {
      expect(classifyCmccPage('手机号 验证码 获取验证码 登录'),
          CmccPageKind.login);
      expect(classifyCmccPage('请登录后查看'), CmccPageKind.login);
    });

    test('维护特征', () {
      expect(classifyCmccPage('系统优化升级公告 请稍后再试'),
          CmccPageKind.maintenance);
      expect(classifyCmccPage('升级公告'), CmccPageKind.maintenance);
    });

    test('首页特征（登录成功判据）', () {
      expect(classifyCmccPage('话费余额 12.34 元'), CmccPageKind.home);
      expect(classifyCmccPage('我的 套餐余量 退出'), CmccPageKind.home);
    });

    test('空 / 不认识', () {
      expect(classifyCmccPage(''), CmccPageKind.unknown);
      expect(classifyCmccPage('   '), CmccPageKind.unknown);
      expect(classifyCmccPage('something else'), CmccPageKind.unknown);
      expect(cmccKindMessage(CmccPageKind.unknown), kCmccFailUnknownPage);
      expect(cmccKindMessage(CmccPageKind.maintenance), kCmccFailMaintenance);
      expect(cmccKindMessage(CmccPageKind.login), kCmccFailNeedLogin);
    });

    test('优先级：登录页判据先于首页判据（登录页底部常有"我的/余额"字样）', () {
      expect(classifyCmccPage('获取验证码 我的 余额'), CmccPageKind.login);
    });
  });

  group('⑥ 会话失效判定', () {
    test('明确的"未登录"字样才算失效', () {
      expect(looksLikeSessionExpired('{"code":"-1","msg":"请登录"}'), isTrue);
      expect(looksLikeSessionExpired('登录已过期，请重新登录'), isTrue);
      expect(looksLikeSessionExpired('未登录'), isTrue);
      expect(looksLikeSessionExpired(''), isFalse);
      expect(looksLikeSessionExpired('话费余额 12.34 元'), isFalse,
          reason: '"登录"两个字不能当失效判据（页头就有），否则会白让用户重收短信');
      expect(looksLikeSessionExpired('退出'), isFalse);
    });
  });

  group('⑦ 手机号脱敏（日志与界面只允许出现尾号）', () {
    test('11 位号码 → ****+尾号 4 位', () {
      expect(cmccPhoneTail('13800138000'), '****8000');
      expect(cmccPhoneTail('198 1234 5678'), '****5678');
      expect(cmccPhoneTail('198-1234-5678'), '****5678');
    });

    test('拿不到 / 太短 → null（宁可不显示，也不显示错的）', () {
      expect(cmccPhoneTail(null), isNull);
      expect(cmccPhoneTail(''), isNull);
      expect(cmccPhoneTail('12'), isNull);
    });
  });

  group('⑧ 轮询 / 退避策略', () {
    test('正常 30 分钟一次', () {
      final p = cmccNextPollPlan(consecutiveFailures: 0, needsRelogin: false);
      expect(p.poll, isTrue);
      expect(p.delay, kCmccPollInterval);
      expect(kCmccPollInterval, const Duration(minutes: 30));
    });

    test('失败退避 5 分钟；连续 3 次 → 1 小时', () {
      for (final n in [1, 2]) {
        final p = cmccNextPollPlan(consecutiveFailures: n, needsRelogin: false);
        expect(p.poll, isTrue);
        expect(p.delay, kCmccRetryBackoff);
        expect(p.reason, contains('5 分钟'));
      }
      for (final n in [3, 7, 99]) {
        final p = cmccNextPollPlan(consecutiveFailures: n, needsRelogin: false);
        expect(p.poll, isTrue);
        expect(p.delay, kCmccLongBackoff);
        expect(p.reason, contains('1 小时'));
      }
    });

    test('需要重新登录 → **不轮询**（不管失败几次）', () {
      for (final n in [0, 1, 3]) {
        final p = cmccNextPollPlan(consecutiveFailures: n, needsRelogin: true);
        expect(p.poll, isFalse);
        expect(p.delay, isNull, reason: '停下等用户自己重登，不许排下一次');
        expect(p.reason, contains('停止'));
      }
    });

    test('任何间隔都不短于 5 分钟（硬下限，写错也退不回去）', () {
      expect(clampCmccInterval(const Duration(seconds: 1)),
          kCmccMinInterval);
      expect(clampCmccInterval(const Duration(minutes: 12)),
          const Duration(minutes: 12));
      for (var n = 0; n <= 10; n++) {
        final p = cmccNextPollPlan(consecutiveFailures: n, needsRelogin: false);
        expect(p.delay! >= kCmccMinInterval, isTrue,
            reason: '$n 次失败时排出的间隔短于 5 分钟');
      }
    });

    test('失败计数封顶在 3（不给用户看"失败了 27 次"这种数字）', () {
      expect(cmccBumpFailures(0), 1);
      expect(cmccBumpFailures(2), 3);
      expect(cmccBumpFailures(3), 3);
      expect(cmccBumpFailures(99), 3);
      expect(cmccResetFailures(), 0);
    });
  });

  group('⑨ 点页面文案的白名单 / 黑名单（红线：绝不自动重发验证码）', () {
    test('刷新类允许点', () {
      for (final t in kCmccPokeTexts) {
        expect(cmccMayClickText(t), isTrue, reason: '$t 在白名单里却不让点');
      }
      expect(cmccMayClickText(' 点击刷新 '), isTrue,
          reason: '页面文案前后可能有空白');
    });

    test('验证码 / 登录 / 退出类一律不许点（哪怕它同时含"刷新"字样）', () {
      for (final t in kCmccForbiddenPokeTexts) {
        expect(cmccMayClickText(t), isFalse, reason: '$t 是黑名单却能让点');
      }
      expect(cmccMayClickText('点击刷新获取验证码'), isFalse,
          reason: '黑名单优先：这种混在一起的文案绝对不能点');
      expect(cmccMayClickText('刷新 发送验证码'), isFalse);
      expect(cmccMayClickText('登录'), isFalse);
      expect(cmccMayClickText(''), isFalse);
      expect(cmccMayClickText('   '), isFalse);
      expect(cmccMayClickText('立即办理'), isFalse, reason: '白名单之外一律不点');
    });

    test('黑名单与白名单不冲突（同一个词不会既允许又禁止）', () {
      for (final allow in kCmccPokeTexts) {
        for (final deny in kCmccForbiddenPokeTexts) {
          expect(allow.contains(deny), isFalse,
              reason: '"$allow" 里不该含黑名单词 "$deny"');
          expect(deny.contains(allow), isFalse,
              reason: '"$deny" 里不该含白名单词 "$allow"');
        }
      }
    });
  });

  group('⑩ 小字长度契约（用户要求设置里的小字不超过两行）', () {
    test('掌厅相关常量：非空白字符 ≤ 42', () {
      final texts = <String, String>{
        'kCmccGroup': kCmccGroup,
        'kCmccIntro': kCmccIntro,
        'kCmccStateLoggedOut': kCmccStateLoggedOut,
        'kCmccStateLoggedIn': kCmccStateLoggedIn,
        'kCmccStateNeedRelogin': kCmccStateNeedRelogin,
        'kCmccNoDirectional': kCmccNoDirectional,
        'kCmccLoginHint': kCmccLoginHint,
        'kCmccManualFallback': kCmccManualFallback,
        'kCmccFailNoResponse': kCmccFailNoResponse,
        'kCmccFailDecrypt': kCmccFailDecrypt,
        'kCmccFailNoGeneral': kCmccFailNoGeneral,
        'kCmccFailUnknownUnit': kCmccFailUnknownUnit,
        'kCmccFailNoText': kCmccFailNoText,
        'kCmccFailMaintenance': kCmccFailMaintenance,
        'kCmccFailNeedLogin': kCmccFailNeedLogin,
        'kCmccFailUnknownPage': kCmccFailUnknownPage,
        'kCmccFallbackHint': kCmccFallbackHint,
        'kCmccFailBoth': kCmccFailBoth,
        'kCmccReloginReason': kCmccReloginReason,
      };
      texts.forEach((name, text) {
        final n = text.replaceAll(RegExp(r'\s'), '').length;
        expect(n, lessThanOrEqualTo(42), reason: '$name 有 $n 个非空白字符');
      });
    });

    test('轮询计划的那句话也要 ≤ 42（它是界面小字的一部分）', () {
      for (var n = 0; n <= 5; n++) {
        for (final need in [true, false]) {
          final reason =
              cmccNextPollPlan(consecutiveFailures: n, needsRelogin: need)
                  .reason;
          final count = reason.replaceAll(RegExp(r'\s'), '').length;
          expect(count, lessThanOrEqualTo(42), reason: '"$reason" 太长');
        }
      }
    });
  });
}
