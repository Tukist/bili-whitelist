import 'dart:convert';

import 'package:crypto/crypto.dart';

/// WBI 签名器 —— 从 M0 产物 `probe.py` 逐行移植的算法（本项目自行实现，未复制任何 GPL 源码）。
///
/// 参考事实（probe.md 2026-08 实测）：
/// - nav 接口匿名即可拿到 wbi_img（img_url / sub_url）
/// - key 从 URL 文件名提取；mixinKey = 置换表取 (img_key + sub_key) 前 32 位
/// - 签名 = 参数加 wts 时间戳 → 去除参数值非法字符 !'()* → 按 key 排序后
///   urlencode → md5(编码串 + mixinKey) → 得到 w_rid
///
/// 实测 golden（probe.md 5.1/5.2）：
///   img_key=7cd084941338484aae1ad9425b84077c
///   sub_key=4932caff0ff746eab6f01bf08b70ac45
///   mixin_key=ea1db124af3c7062474693fa704f4ff8
const List<int> _mixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
  49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
  40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
  62, 11, 36, 20, 34, 44, 52,
];

class WbiSigner {
  /// 从 img_key+sub_key 拼接串按置换表生成 32 位 mixinKey。
  static String getMixinKey(String orig) {
    final buf = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buf.write(orig[_mixinKeyEncTab[i]]);
    }
    return buf.toString();
  }

  /// 从 wbi_img 的 img_url/sub_url 提取 key（取文件名去扩展名）。
  static String getKeyFromUrl(String url) {
    final seg = url.split('/').last;
    return seg.split('.').first;
  }

  /// 给参数字典附加 wbi 签名（wts + 排序 + urlencode + md5 -> w_rid）。
  ///
  /// - [withDm] 与 whitelist.py 一致：附加 dm_img_list / dm_img_str /
  ///   dm_cover_img_str 三个参数（2026-08 实测可绕过匿名 view 请求的 -412 风控）
  /// - [wts] 仅供测试注入固定时间戳；生产调用不传（自动取当前秒级时间戳）
  static Map<String, String> encodeWbi(
    Map<String, String> params, {
    required String imgKey,
    required String subKey,
    bool withDm = true,
    int? wts,
  }) {
    final mixinKey = getMixinKey(imgKey + subKey);
    final p = Map<String, String>.from(params);
    p['wts'] =
        (wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    if (withDm) {
      p['dm_img_list'] = '[]';
      p['dm_img_str'] = 'V2ViR0wgMS4w';
      p['dm_cover_img_str'] = 'QU5HTEU=';
    }
    // B 站要求去除参数值中的非法字符 !'()*
    final cleaned = <String, String>{};
    p.forEach((k, v) {
      cleaned[k] = v.replaceAll(RegExp(r"[!'()*]"), '');
    });
    // 按 key 排序后 urlencode（等价 Python urllib.parse.urlencode(sorted(...))）
    final keys = cleaned.keys.toList()..sort();
    final query =
        keys.map((k) => '${_quotePlus(k)}=${_quotePlus(cleaned[k]!)}').join('&');
    p['w_rid'] = md5.convert(utf8.encode(query + mixinKey)).toString();
    return p;
  }

  /// 模拟 Python `urllib.parse.quote_plus`（safe=''）：
  /// 只保留 unreserved 字符（A-Z a-z 0-9 - _ . ~），空格转 '+',
  /// 其余字符按 UTF-8 字节做百分号编码。保证与服务端签名串完全一致。
  static String _quotePlus(String s) {
    const unreserved = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        'abcdefghijklmnopqrstuvwxyz'
        '0123456789-_.~';
    final out = StringBuffer();
    for (final ch in s.split('')) {
      if (ch == ' ') {
        out.write('+');
      } else if (unreserved.contains(ch)) {
        out.write(ch);
      } else {
        for (final b in utf8.encode(ch)) {
          out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return out.toString();
  }
}
