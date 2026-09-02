// 弹幕单元测试：
// - parseDanmakuXml：正常解析（滚动/顶部/底部/字号/颜色）、脏行容错跳过、
//   XML 实体反转义、时间升序、空/弹幕关闭 XML → 空列表
// - danmakuDisplayFontSize：档位映射
// - fetchDanmaku（mock dio）：deflate 压缩响应解压解析、明文 XML、
//   网络错误静默返回空
// 不访问真实网络。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/danmaku.dart';

/// 构造一条 d 标签 XML：p 前 4 段 + 可选额外段（rowid 等新字段）。
String _dXml(String text,
    {String time = '1.5', String mode = '1', String font = '25', String color = '16777215'}) {
  return '<d p="$time,$mode,$font,$color,1788275674,0,f1a6f248,2190974172275645184,10">$text</d>';
}

/// 完整 XML：i 标签内包若干 d 标签。
String _wrapXml(String dTags) =>
    '<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com'
    '</chatserver><chatid>1</chatid><mission>0</mission><maxlimit>1000</maxlimit>'
    '<state>0</state>$dTags</i>';

/// 生成 raw deflate（RFC1951）字节：模拟 B 站 list.so 的 Content-Encoding: deflate。
List<int> _rawDeflateBytes(String text) =>
    ZLibCodec(raw: true).encode(utf8.encode(text));

/// 返回明文/压缩 body 的 adapter。
class _BodyAdapter implements HttpClientAdapter {
  final List<int> Function() body;
  final Map<String, List<String>> headers;

  _BodyAdapter(this.body, {this.headers = const {}});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(
      body(),
      200,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 抛连接错误的 adapter（模拟断网）。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('parseDanmakuXml', () {
    test('正常解析：滚动/顶部/底部 + 时间秒数 + 文本', () {
      final xml = _wrapXml([
        _dXml('滚动弹幕', time: '10.5', mode: '1'),
        _dXml('顶部弹幕', time: '0.8', mode: '5'),
        _dXml('底部弹幕', time: '5.0', mode: '4'),
      ].join());
      final list = parseDanmakuXml(xml);
      expect(list, hasLength(3));
      // 按时间升序：0.8 顶部 → 5.0 底部 → 10.5 滚动
      expect(list[0].timeSec, 0.8);
      expect(list[0].isTop, isTrue);
      expect(list[0].text, '顶部弹幕');
      expect(list[1].mode, 4);
      expect(list[1].isBottom, isTrue);
      expect(list[2].mode, 1);
      expect(list[2].isScroll, isTrue);
      expect(list[2].text, '滚动弹幕');
    });

    test('字号/颜色：fontsize=25、color 十进制 RGB → ARGB', () {
      // 16776960 = 0xFFFF00 黄色（RGB 无 alpha）
      final list = parseDanmakuXml(_wrapXml(_dXml('黄', color: '16776960')));
      expect(list.single.fontSize, 25);
      expect(list.single.color, 0xFFFFFF00);
    });

    test('非默认模式（如 2）按滚动处理', () {
      final list = parseDanmakuXml(_wrapXml(_dXml('特殊模式', mode: '2')));
      expect(list.single.mode, 2);
      expect(list.single.isScroll, isTrue);
      expect(list.single.isTop, isFalse);
    });

    test('XML 实体反转义（&lt; &amp;）', () {
      final list = parseDanmakuXml(_wrapXml(_dXml('a&amp;b &lt;c&gt;')));
      expect(list.single.text, 'a&b <c>');
    });

    test('脏行容错：p 字段缺段/类型非法/空文本 → 跳过该条', () {
      final xml = _wrapXml([
        '<d p="1.0">缺字段</d>',
        '<d p="abc,1,25,16777215">时间非数字</d>',
        '<d p="1.0,1,25,xyz">颜色非数字</d>',
        '<d p="2.0,1,25,16777215">   </d>', // 空白文本
        _dXml('好弹幕', time: '3.0'),
      ].join());
      final list = parseDanmakuXml(xml);
      expect(list, hasLength(1));
      expect(list.single.text, '好弹幕');
    });

    test('弹幕关闭 / 无弹幕 XML（无 <d>）→ 空列表', () {
      const closed =
          '<?xml version="1.0"?><i><chatid>1</chatid><state>2</state>'
          '<text>本视频弹幕功能已被关闭</text></i>';
      expect(parseDanmakuXml(closed), isEmpty);
      expect(parseDanmakuXml(''), isEmpty);
      expect(parseDanmakuXml('not xml at all'), isEmpty);
    });
  });

  group('danmakuDisplayFontSize', () {
    test('常见档位映射', () {
      expect(danmakuDisplayFontSize(12), 12);
      expect(danmakuDisplayFontSize(16), 14);
      expect(danmakuDisplayFontSize(18), 15);
      expect(danmakuDisplayFontSize(25), 17);
      expect(danmakuDisplayFontSize(36), 22);
    });

    test('未知档位线性缩放且夹在 11~24', () {
      expect(danmakuDisplayFontSize(20), greaterThanOrEqualTo(11));
      expect(danmakuDisplayFontSize(20), lessThanOrEqualTo(24));
      expect(danmakuDisplayFontSize(100), 24); // 上限
      expect(danmakuDisplayFontSize(1), 11); // 下限
    });
  });

  group('fetchDanmaku', () {
    test('deflate 压缩响应：解压 + 解析（带 Referer/UA 头）', () async {
      final xml = _wrapXml([
        _dXml('第一条', time: '0.5'),
        _dXml('第二条', time: '2.0', color: '16776960'),
      ].join());
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _BodyAdapter(
        () => _rawDeflateBytes(xml),
        headers: {
          'content-type': ['text/xml'],
          'content-encoding': ['deflate'],
        },
      );
      final api = BiliApi(dio: dio);

      final list = await api.fetchDanmaku(12345);

      expect(list, hasLength(2));
      expect(list[0].text, '第一条');
      expect(list[0].timeSec, 0.5);
      expect(list[1].color, 0xFFFFFF00);
    });

    test('明文 XML（无压缩头）也解析', () async {
      final xml = _wrapXml(_dXml('明文弹幕'));
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _BodyAdapter(
        () => utf8.encode(xml),
        headers: {
          'content-type': ['text/xml'],
        },
      );

      final list = await BiliApi(dio: dio).fetchDanmaku(1);
      expect(list, hasLength(1));
      expect(list.single.text, '明文弹幕');
    });

    test('弹幕关闭（无 <d>）→ 空列表', () async {
      const closed = '<i><state>2</state>'
          '<text>本视频弹幕功能已被关闭</text></i>';
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _BodyAdapter(
        () => ZLibCodec(raw: true).encode(utf8.encode(closed)),
        headers: {
          'content-type': ['text/xml'],
          'content-encoding': ['deflate'],
        },
      );

      expect(await BiliApi(dio: dio).fetchDanmaku(1), isEmpty);
    });

    test('网络错误 → 静默返回空（不抛）', () async {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();

      expect(await BiliApi(dio: dio).fetchDanmaku(1), isEmpty);
    });
  });
}
