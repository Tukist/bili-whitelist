// 掌厅 AES-128-CBC/PKCS7 解密单测（v2.54.0）。
//
// 覆盖：手写实现的分组解密本身（FIPS-197 标准向量）、CBC 串联 + PKCS7 去填充
// （**自造向量**：用同一个 key/IV 手工加密一段 JSON，再断言解得回来）、
// 「这条响应是密文还是明文」的判定规则、以及各种坏输入必须**抛异常而不是
// 返回半个结果**。
//
// ⚠️ 这里**不使用任何真实的运营商响应**：向量要么是 FIPS-197 公开标准值，
// 要么是本文件自己造的。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/cmcc_aes.dart';

/// 掌厅网页 JS 里那两个常量（网页自己明文写着，不是本 App 的秘密）。
final Uint8List _key = Uint8List.fromList(ascii.encode('1234123412ABCDEF'));
final Uint8List _iv = Uint8List.fromList(ascii.encode('ABCDEF1234123412'));

/// 自造向量 1：明文 `{"a":1}`（PKCS7 补到 16 字节）的 CBC 密文。
const String _cipherSmall = 'c809c67a56cdce58834b9f6c2e729973';
const String _plainSmall = '{"a":1}';

/// 自造向量 2：一份余量 JSON（形态照调研里的字段，数字是编的）。
const String _plainMargin =
    '{"code":"0000","data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
    '{"usedNum":"6.05","remainNum":"73.95","sumNum":"80","unit":"04"},'
    '"directionalFlowInfo":{"usedNum":"3.22","remainNum":"26.78","sumNum":"30","unit":"04"},'
    '"otherRemian":{"usedNum":"0","remainNum":"0","sumNum":"0","unit":"04"},'
    '"totalInfo":{"usedNum":"9.27","remainNum":"100.73","sumNum":"110","unit":"04"}}}}}';
const String _cipherMargin =
    '1567779d8f74e2926e1b2eb3ae12c34f5bfa5477999858bd85f28f1c716da40fa952828348c7ae11550873dd8dc0eaf4ba9b7af8ac7299579f3ce25fd9bf9497ab4255dcec20cf2dd58d4bc4d93bbdf63bb3dc7cca0cc2bf4db070546d3404c2d51061128146fb993dc3bf0daff54ebaabdec0d1a011d8fad19fd01caea78bf22f7aefb11a042b7065eee5b742bd291e9748c07ddd20ee7bde45d6ea516b12208cb3ff1f6b4e2fad5885fe055eaa9c89e304ddb800ac8d9f15d1b7afa46701d4baaeaadeedab5ff0c81fc147eb6ca1d19e162472b74e757acfcd98db5e57e157e339a1f359a9208b6d52e2d966dd2f061f2b1c5aaa5efc70e72ed0a04935a0605e5f8e3636eff0356472852d5fef748dc7d362cab8415875b393b1821adfb939952f924099f809f4b8be61d96bb311dcf0d7771f19f9519cebea74c2135d34f8ccf0bf13a6943a4dc2cf60d7ed14c96b8ee5183d16be0d1be1a896d7580b12ceabdc569011443d2adba13050866db4292b8d869c634bd1528228982e3dbebbb8';

void main() {
  group('① 分组解密本身（FIPS-197 标准向量）', () {
    test('AES-128 单分组解密 = 标准值', () {
      final key = Uint8List.fromList([
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, //
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
      ]);
      final block = Uint8List.fromList([
        0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, //
        0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
      ]);
      final plain = aes128DecryptBlock(key, block);
      expect(bytesToHex(plain),
          '00112233445566778899aabbccddeeff',
          reason: 'FIPS-197 附录 B/C 的 AES-128 向量，对不上说明实现本身错了');
    });

    test('GF(2^8) 乘法：FIPS-197 的样例 {57}·{83} = {c1}', () {
      expect(gfMul(0x57, 0x83), 0xc1);
      expect(gfMul(1, 0xab), 0xab);
      expect(gfMul(0, 0xab), 0);
      expect(gfMul(2, 0x80), 0x1b, reason: '溢出要按 0x1b 约简');
    });

    test('分组长度不对 → 抛 ArgumentError（不静默返回半截）', () {
      expect(() => aes128DecryptBlock(_key, Uint8List(15)),
          throwsA(isA<ArgumentError>()));
      expect(() => aes128DecryptBlock(Uint8List(15), Uint8List(16)),
          throwsA(isA<ArgumentError>()), reason: 'AES-128 只收 16 字节密钥');
    });
  });

  group('② CBC + PKCS7（自造向量）', () {
    test('解回来的明文一字不差', () {
      final a = aes128CbcDecrypt(_key, _iv, hexToBytes(_cipherSmall));
      expect(utf8.decode(a), _plainSmall);

      final b = aes128CbcDecrypt(_key, _iv, hexToBytes(_cipherMargin));
      expect(utf8.decode(b), _plainMargin);
      // 解出来的确实是一份能 parse 的 JSON（顺带证明填充长度对）
      expect(jsonDecode(utf8.decode(b)), isA<Map<String, Object?>>());
    });

    test('IV / 密文长度不合法 → 抛 ArgumentError', () {
      expect(() => aes128CbcDecrypt(_key, Uint8List(15), hexToBytes(_cipherSmall)),
          throwsA(isA<ArgumentError>()));
      expect(() => aes128CbcDecrypt(_key, _iv, hexToBytes('00112233')),
          throwsA(isA<ArgumentError>()), reason: '4 字节不是完整分组');
      expect(() => aes128CbcDecrypt(_key, _iv, Uint8List(0)),
          throwsA(isA<ArgumentError>()), reason: '空密文没有意义');
    });

    test('key 不对 → 填充自检不过，抛 FormatException（不把垃圾当数据）', () {
      final wrong = Uint8List.fromList(ascii.encode('ABCDEF1234123412'));
      expect(() => aes128CbcDecrypt(wrong, _iv, hexToBytes(_cipherSmall)),
          throwsA(isA<FormatException>()));
    });

    test('PKCS7 去填充：合法/非法各自的判定', () {
      expect(pkcs7Unpad(Uint8List.fromList([1, 2, 3, 4, 5, 3, 3, 3])),
          [1, 2, 3, 4, 5]);
      expect(pkcs7Unpad(Uint8List.fromList([7, 1])), [7]);
      expect(() => pkcs7Unpad(Uint8List(0)), throwsA(isA<FormatException>()));
      expect(() => pkcs7Unpad(Uint8List.fromList([1, 2, 3, 0])),
          throwsA(isA<FormatException>()), reason: '填充长度 0 非法');
      expect(() => pkcs7Unpad(Uint8List.fromList([1, 2, 3, 17])),
          throwsA(isA<FormatException>()), reason: '填充长度超过分组');
      expect(() => pkcs7Unpad(Uint8List.fromList([1, 2, 4, 4, 5, 4])),
          throwsA(isA<FormatException>()), reason: '尾部填充字节不一致');
    });
  });

  group('③ 「密文还是明文」的判定规则', () {
    test('长度 ≥32 + 是 32 的倍数 + 全 hex → 当密文', () {
      expect(looksLikeCipherHex(_cipherSmall), isTrue, reason: '32 位 hex');
      expect(looksLikeCipherHex(_cipherMargin), isTrue, reason: '长 hex');
      expect(looksLikeCipherHex('  $_cipherSmall  '), isTrue,
          reason: '前后空白要先去掉再判');
      expect(looksLikeCipherHex('ABCDEF0123456789ABCDEF0123456789'), isTrue,
          reason: '大写 hex 也算');
    });

    test('不满足就按明文处理（别硬解）', () {
      expect(looksLikeCipherHex('{"a":1}'), isFalse, reason: '明文 JSON');
      expect(looksLikeCipherHex(''), isFalse);
      expect(looksLikeCipherHex('abc'), isFalse, reason: '太短');
      expect(looksLikeCipherHex('0123456789abcdef0123456789abcde'),
          isFalse, reason: '31 位：不是 32 的倍数');
      expect(looksLikeCipherHex('0123456789abcdef0123456789abcdeg'),
          isFalse, reason: '有非 hex 字符');
      expect(looksLikeCipherHex('0123456789abcdef0123456789abcd 12'),
          isFalse, reason: 'hex 串里不该有内嵌空格');
    });

    test('hex 与字节互为逆运算；奇数长度 / 非法字符要抛', () {
      final bytes = hexToBytes('00ff10');
      expect(bytes, [0, 255, 16]);
      expect(bytesToHex(bytes), '00ff10');
      expect(() => hexToBytes('abc'), throwsA(isA<FormatException>()));
      expect(() => hexToBytes('zz'), throwsA(isA<FormatException>()));
    });
  });
}
