// 临时探测脚本：真实网络验证 B 站搜索接口（WBI 签名 + buvid 指纹 + 完整浏览器头）。
// 运行：dart run tools/e2e_search_check.dart
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

  // 1) buvid 指纹
  final spi = await dio.get<Map<String, dynamic>>('/x/frontend/finger/spi');
  final sd = spi.data?['data'] as Map<String, dynamic>? ?? {};
  final cookie =
      'buvid3=${sd['b_3']}; buvid4=${sd['b_4']}';
  dio.options.headers['Cookie'] = cookie;
  print('spi ok: buvid3=${(sd['b_3'] as String? ?? '').substring(0, 8)}...');

  // 2) nav 拿 wbi key
  final nav = await dio.get<Map<String, dynamic>>('/x/web-interface/nav');
  final wbi = (nav.data?['data'] as Map<String, dynamic>?)?['wbi_img']
      as Map<String, dynamic>?;
  final imgKey = WbiSigner.getKeyFromUrl(wbi?['img_url'] as String? ?? '');
  final subKey = WbiSigner.getKeyFromUrl(wbi?['sub_url'] as String? ?? '');
  print('nav code=${nav.data?['code']} img_key=$imgKey sub_key=$subKey');

  // 3) 搜索（带 WBI 签名）
  final params = WbiSigner.encodeWbi({
    'search_type': 'video',
    'keyword': '无职转生',
    'page': '1',
    'page_size': '20',
  }, imgKey: imgKey, subKey: subKey);
  final resp = await dio.get<Map<String, dynamic>>(
      '/x/web-interface/wbi/search/type',
      queryParameters: params);
  print('search code=${resp.data?['code']} message=${resp.data?['message']}');
  final d = resp.data?['data'] as Map<String, dynamic>?;
  if (d == null) {
    print('data null, full=${resp.data}');
    return;
  }
  print('data keys: ${d.keys.toList()}');
  final result = d['result'];
  print('result type=${result.runtimeType}');
  if (result is List && result.isNotEmpty) {
    final first = (result.first as Map).cast<String, dynamic>();
    print('result[0] keys: ${first.keys.toList()}');
    print('bvid=${first['bvid']}');
    print('title=${first['title']}');
    print('author=${first['author']}');
    print('pic=${first['pic']}');
    print('duration=${first['duration']} (${first['duration'].runtimeType})');
    print('play=${first['play']} (${first['play'].runtimeType})');
    print('pubdate=${first['pubdate']} (${first['pubdate'].runtimeType})');
  } else {
    print('result empty/not list: ${d['result']}');
  }
}
