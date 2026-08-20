// M2 端到端验证脚本：真实网络下验证 WBI 签名层 + 接口调用。
//
// 运行：dart run tools/e2e_wbi_check.dart
// 覆盖：nav 拿 key → view 带签名 → playurl 带签名（只读，不写任何东西）
// ignore_for_file: avoid_print
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/wbi/wbi_signer.dart';
import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://api.bilibili.com',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: biliHeaders(),
  ));

  // 1) nav 匿名拿 wbi key（实测 code=-101 未登录，但 wbi_img 仍返回）
  final nav = await dio.get<Map<String, dynamic>>('/x/web-interface/nav');
  final wbi = (nav.data?['data'] as Map<String, dynamic>?)?['wbi_img']
      as Map<String, dynamic>?;
  final imgKey = WbiSigner.getKeyFromUrl(wbi?['img_url'] as String? ?? '');
  final subKey = WbiSigner.getKeyFromUrl(wbi?['sub_url'] as String? ?? '');
  print('nav code=${nav.data?['code']}');
  print('img_key=$imgKey sub_key=$subKey');
  print('mixin_key=${WbiSigner.getMixinKey(imgKey + subKey)}');

  // 2) view 带 WBI 签名（fnval 参数无关，纯验证签名可过）
  final p1 = WbiSigner.encodeWbi({'bvid': 'BV1xx411c7mD'},
      imgKey: imgKey, subKey: subKey);
  final view = await dio.get<Map<String, dynamic>>('/x/web-interface/view',
      queryParameters: p1);
  final vd = view.data?['data'] as Map<String, dynamic>?;
  print('view code=${view.data?['code']} '
      'title=${vd?['title']} cid=${vd?['cid']}');

  // 3) playurl 带 WBI 签名（mp4 单流 qn=64）
  final p2 = WbiSigner.encodeWbi(
    {
      'bvid': 'BV1xx411c7mD',
      'cid': '62131',
      'qn': '64',
      'fnval': '0',
      'fnver': '0',
      'fourk': '1',
    },
    imgKey: imgKey,
    subKey: subKey,
  );
  final pl = await dio.get<Map<String, dynamic>>('/x/player/wbi/playurl',
      queryParameters: p2);
  final pd = pl.data?['data'] as Map<String, dynamic>?;
  final durl = (pd?['durl'] as List?)?.first as Map<String, dynamic>?;
  final url = durl?['url'] as String? ?? '';
  print('playurl code=${pl.data?['code']} quality=${pd?['quality']} '
      'url=${url.substring(0, url.length > 70 ? 70 : url.length)}...');

  print(url.isNotEmpty
      ? 'E2E_OK: WBI 签名 + view + playurl 全部通过'
      : 'E2E_WARN: 未拿到流地址');
}
