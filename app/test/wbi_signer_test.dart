import 'package:bili_whitelist_app/wbi/wbi_signer.dart';
import 'package:flutter_test/flutter_test.dart';

/// WBI 签名器单元测试。
///
/// golden 用例基准来源：probe.md 实测的 img_key/sub_key/mixin_key，
/// 以及用 `python -c "import probe; ..."`（probe.py 的 encode_wbi 算法）
/// 对固定 wts=1755585600 生成的 w_rid 真值：
///   query1（带 dm 参数）: w_rid = 9015d5c508d03f45c4dd6f2f749774d8
///   query2（不带 dm）  : w_rid = 1729e56901f86e2872fa1f06dc363500
///   query3（非法字符） : w_rid = 59f7a6b5520d191c7bf2b650f92c5e56
void main() {
  // probe.md 实测 key（2026-08-20，B 站 nav 接口返回）
  const imgKey = '7cd084941338484aae1ad9425b84077c';
  const subKey = '4932caff0ff746eab6f01bf08b70ac45';
  const wts = 1755585600;

  group('getKeyFromUrl', () {
    test('从 img_url 提取 img_key', () {
      expect(
        WbiSigner.getKeyFromUrl(
            'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png'),
        imgKey,
      );
    });

    test('从 sub_url 提取 sub_key', () {
      expect(
        WbiSigner.getKeyFromUrl(
            'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png'),
        subKey,
      );
    });
  });

  group('getMixinKey', () {
    test('置换表生成结果与 probe.md 实测 mixin_key 一致', () {
      expect(WbiSigner.getMixinKey(imgKey + subKey),
          'ea1db124af3c7062474693fa704f4ff8');
    });
  });

  group('encodeWbi', () {
    test('带 dm 参数：w_rid golden 一致（对应 whitelist.py 生产签名）', () {
      final signed = WbiSigner.encodeWbi(
        {'bvid': 'BV1xx411c7mD'},
        imgKey: imgKey,
        subKey: subKey,
        withDm: true,
        wts: wts,
      );
      expect(signed['wts'], '$wts');
      expect(signed['dm_img_list'], '[]');
      expect(signed['dm_img_str'], 'V2ViR0wgMS4w');
      expect(signed['dm_cover_img_str'], 'QU5HTEU=');
      expect(signed['w_rid'], '9015d5c508d03f45c4dd6f2f749774d8');
    });

    test('不带 dm：w_rid golden 一致（对应 probe.py 基本版签名）', () {
      final signed = WbiSigner.encodeWbi(
        {'bvid': 'BV1xx411c7mD', 'qn': '80', 'fnval': '0'},
        imgKey: imgKey,
        subKey: subKey,
        withDm: false,
        wts: wts,
      );
      expect(signed.containsKey('dm_img_list'), isFalse);
      expect(signed['w_rid'], '1729e56901f86e2872fa1f06dc363500');
    });

    test('参数值中的非法字符 !\'()* 只在签名串中剔除，w_rid golden 一致', () {
      final signed = WbiSigner.encodeWbi(
        {'bvid': "BV!abc()x*Y"},
        imgKey: imgKey,
        subKey: subKey,
        withDm: false,
        wts: wts,
      );
      // 与 probe.py 一致：返回的请求参数保留原值，
      // 非法字符仅在计算 w_rid 的编码串中被剔除
      expect(signed['bvid'], "BV!abc()x*Y");
      expect(signed['w_rid'], '59f7a6b5520d191c7bf2b650f92c5e56');
    });

    test('原参数不被修改（纯函数）', () {
      final params = {'bvid': 'BV1xx411c7mD'};
      WbiSigner.encodeWbi(
        params,
        imgKey: imgKey,
        subKey: subKey,
        withDm: true,
        wts: wts,
      );
      expect(params, {'bvid': 'BV1xx411c7mD'});
    });
  });

  group('_quotePlus 语义（经 w_rid 间接验证）', () {
    test('键排序后编码顺序与 Python sorted(urlencode) 一致', () {
      // 多参数混合：编码串顺序由 key 字母序决定
      final signed = WbiSigner.encodeWbi(
        {'fourk': '1', 'fnval': '16', 'cid': '62131', 'qn': '80', 'bvid': 'BV1xx411c7mD'},
        imgKey: imgKey,
        subKey: subKey,
        withDm: false,
        wts: wts,
      );
      // Python 独立验证过：query=bvid=BV1xx411c7mD&cid=62131&fnval=16&fourk=1&qn=80&wts=1755585600
      expect(signed['w_rid'], 'e1ae49f1030326eeffab8555ad3fdcb3');
      expect(signed['w_rid'], hasLength(32));
    });
  });
}
