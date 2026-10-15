// 掌厅注入脚本与回传消息单测（v2.54.0）。
//
// 这一层测的是**要发到用户手机上的那段 JS**与它回传的消息解析：
// - 脚本必须钩住 `fetch` 与 `XMLHttpRequest`，只回传关心的那几个接口；
// - 脚本点页面文案前**必须先过黑名单**（验证码/登录/退出一律不点）——这是
//   "绝不自动重发验证码"这条红线在代码里唯一的落点，所以要对着**成品脚本**
//   断言，不是对着注释；
// - 脚本里**不应该出现**任何写输入框 / 点登录按钮的代码（不代填、不代登录）；
// - 回传消息解析要能扛住垃圾数据（静默丢弃，不抛）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/cmcc_hook_script.dart';
import 'package:bili_whitelist_app/services/cmcc_plan.dart';

void main() {
  final script = buildCmccHookScript();

  group('① 注入脚本：钩子覆盖', () {
    test('钩住 fetch（含 clone 后读文本，不破坏页面自己拿响应）', () {
      expect(script, contains('window.fetch = function'));
      expect(script, contains('r.clone().text()'));
      expect(script, contains("post({kind: 'response'"));
    });

    test('钩住 XMLHttpRequest 的 open + send', () {
      expect(script, contains('XMLHttpRequest.prototype.open'));
      expect(script, contains('XMLHttpRequest.prototype.send'));
      expect(script, contains('addEventListener'));
    });

    test('只回传关心的那四个接口名（筛选在页面里就做掉）', () {
      for (final api in kCmccWantedApis) {
        expect(script, contains(api), reason: '$api 应该在筛选表里');
      }
      expect(script, contains('function hit(u)'));
      expect(script, contains('WANT'));
    });

    test('通道名与安装标记都要一致（Dart 侧靠它们对话 / 探测）', () {
      expect(script, contains('"$kCmccChannel"'));
      expect(script, contains(kCmccHookMarker));
      expect(script, contains('window.$kCmccPokeFunction'));
      expect(script, contains('window.$kCmccTextFunction'));
    });

    test('幂等：重复注入不能把 fetch 再包一层', () {
      expect(script, contains('if (window.$kCmccHookMarker) { return'));
    });

    test('脚本不做 URL 拼接：不写死任何掌厅接口路径', () {
      expect(script, isNot(contains('wx.10086.cn')),
          reason: '路线 C 的意义就是"不自己维护 URL"，页面自己会调');
      expect(script, isNot(contains('getMainPlan?')));
    });
  });

  group('② 注入脚本：红线的代码落点（绝不自动重发验证码）', () {
    test('点文案前必须先过黑名单（成品脚本里就有这个判断）', () {
      expect(script, contains('function isDenied(t)'));
      expect(script, contains('function isAllowed(t)'));
      expect(script, contains('if (isDenied(t)) { return false; }'));
      expect(script, contains('if (!isAllowed(t)) { continue; }'),
          reason: '点击循环里必须先判白名单（白名单内部先判黑名单）');
      expect(script, contains('window.$kCmccPokeFunction = poke'));
    });

    test('黑名单每一条都进了脚本，且 Dart 判定也拦得住', () {
      for (final deny in kCmccForbiddenPokeTexts) {
        expect(script, contains(deny), reason: '$deny 没有进脚本黑名单');
        expect(cmccMayClickText(deny), isFalse, reason: '$deny 不该允许点击');
      }
      expect(kCmccForbiddenPokeTexts, contains('获取验证码'));
      expect(kCmccForbiddenPokeTexts, contains('发送验证码'));
      expect(kCmccForbiddenPokeTexts, contains('重新获取'));
      expect(kCmccForbiddenPokeTexts, contains('登录'));
      expect(kCmccForbiddenPokeTexts, contains('退出'));
    });

    test('白名单每一条也都进了脚本，且只点短文案（≤12 字）', () {
      for (final allow in kCmccPokeTexts) {
        expect(script, contains(allow), reason: '$allow 没有进脚本白名单');
      }
      expect(script, contains('t.length > 12'), reason: '长段落不该被当成按钮点');
    });

    test('脚本里没有任何"代填表单"或"点登录按钮"的代码', () {
      expect(script, isNot(contains('loginBtn')));
      expect(script, isNot(contains('#code')),
          reason: '不碰验证码输入框');
      expect(script, isNot(contains('.value')),
          reason: '脚本不读也不写任何输入框的 value（读手机号在 Dart 侧单独做）');
      expect(script, isNot(contains('dispatchEvent')),
          reason: '只用 click() 点白名单文案，不合成事件');
    });
  });

  group('③ Dart 侧调页面用的那三小段脚本', () {
    test('探测 / 取文字 / 点刷新', () {
      expect(buildCmccProbeScript(), '!!window.$kCmccHookMarker');
      expect(buildCmccTextScript(), 'window.$kCmccTextFunction();');
      expect(buildCmccPokeScript(), 'window.$kCmccPokeFunction();');
    });
  });

  group('④ 回传消息解析', () {
    test('响应消息：api + body', () {
      final msg = parseHookMessage(jsonEncode({
        'kind': 'response',
        'api': 'getNewMarginInfo',
        'body': 'abcdef',
      }))!;
      expect(msg.kind, CmccHookKind.response);
      expect(msg.api, 'getNewMarginInfo');
      expect(msg.body, 'abcdef');
      expect(msg.isWantedApi, isTrue);
      expect(msg.isEmptyBody, isFalse);
      expect(msg.text, isNull);
    });

    test('文字消息：text（可能很大，但不至于 2MB）', () {
      final msg = parseHookMessage(jsonEncode({
        'kind': 'text',
        'text': '话费余额 12.34',
      }))!;
      expect(msg.kind, CmccHookKind.text);
      expect(msg.text, '话费余额 12.34');
      expect(msg.api, isNull);
    });

    test('不在关心列表里的接口 → 不算 wanted（不当数据用）', () {
      final msg = parseHookMessage(jsonEncode({
        'kind': 'response',
        'api': 'someOtherApi',
        'body': 'x',
      }))!;
      expect(msg.isWantedApi, isFalse);
    });

    test('空 body 要能识别出来（钩到了但没内容）', () {
      final msg = parseHookMessage(jsonEncode({
        'kind': 'response',
        'api': 'getMainPlan',
        'body': '   ',
      }))!;
      expect(msg.isEmptyBody, isTrue);
      expect(msg.isWantedApi, isTrue);
    });

    test('垃圾输入一律返回 null（不抛）', () {
      expect(parseHookMessage(''), isNull);
      expect(parseHookMessage('   '), isNull);
      expect(parseHookMessage('不是 json'), isNull);
      expect(parseHookMessage('[1,2,3]'), isNull, reason: '数组不是消息');
      expect(parseHookMessage('"字符串"'), isNull);
      expect(parseHookMessage('{"kind":"unknown"}'), isNull);
      expect(parseHookMessage('{"kind":"response","body":"x"}'), isNull,
          reason: '没有 api 认不出是谁的响应');
      expect(parseHookMessage('{"kind":"response","api":"","body":"x"}'), isNull);
      expect(parseHookMessage('{"kind":"text"}'), isNotNull,
          reason: '文字消息没有 text 字段时给空串，不算垃圾');
    });

    test('超大消息直接丢（防止一次性吃掉内存）', () {
      final huge = jsonEncode({'kind': 'text', 'text': 'x' * 3000000});
      expect(parseHookMessage(huge), isNull);
    });
  });

  group('⑤ JS 返回值解包', () {
    test('字符串结果被 JSON 编码过 → 解回原样', () {
      expect(decodeJsString('"13800138000"'), '13800138000');
      expect(decodeJsString('"true"'), 'true');
      expect(decodeJsString('true'), 'true');
      expect(decodeJsString('13800138000'), '13800138000',
          reason: '解不出来就原样用，宁可多几个引号也不要抛');
      expect(decodeJsString(null), '');
      expect(decodeJsString(''), '');
      expect(decodeJsString('""'), '');
      expect(decodeJsString('"话费余额 12.34"'), '话费余额 12.34');
    });
  });
}
