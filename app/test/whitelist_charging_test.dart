// 充电专属（v2.55.0）模型与解析测试：
// - `WhitelistVideo.charging`：fromJson 容错（缺失/脏类型 → false）、toJson
//   **只在为 true 时输出**、copyWith 透传且能把 true 改回 false；
// - 「老数据零字节变化」：没有 charging 的老 JSON 读进来再写回去，逐字节相同
//   （视频级 + 整份 WhitelistData 级各钉一条）；
// - `parseViewCharging`：view 接口 `data.is_upower_exclusive` 的取值语义
//   （含「不看 is_upower_play / is_upower_preview」的回归断言——那两个字段
//   在普通视频上也是 false，拿去判断会漏标）；
// - `WhitelistWriter.videoFromMeta`：入库时从这个字段解析。
//
// 字段名不是猜的：2026-10 匿名只读探针实测（普通视频 false、标题写明
// 「充电专属」的样本 BV1A18cziEZt / BV1n4SZB9Eut 为 true，且这些样本在未
// 充电账号下取流只拿到试看片段），详见 parseViewCharging 注释。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';

/// 老数据（v2.54 之前）的一条视频：没有任何 v2.55 的新字段。
const String _kOldVideoJson = '{"bvid":"BV1xx411c7mD","cid":62131,'
    '"title":"测试视频","cover":"https://i0.hdslb.com/a.jpg","duration":600,'
    '"up_name":"UP主","added_at":"2026-01-01T00:00:00Z","collection":"","order":0}';

/// 老数据整份白名单：键序与 [WhitelistData.toJson] 一致，便于逐字节比较。
const String _kOldDataJson = '{"version":4,"updated_at":"2026-01-01T00:00:00Z",'
    '"collections":[],"upowners":[],"videos":[$_kOldVideoJson]}';

WhitelistVideo _video({bool charging = false, String bvid = 'BV1xx411c7mD'}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 62131,
      title: '测试视频',
      cover: '',
      duration: 600,
      upName: 'UP主',
      addedAt: '2026-01-01T00:00:00Z',
      charging: charging,
    );

void main() {
  group('WhitelistVideo.charging（v2.55.0+）', () {
    test('fromJson：缺字段 → false（老数据 / 普通视频）', () {
      final v = WhitelistVideo.fromJson(
        jsonDecode(_kOldVideoJson) as Map<String, dynamic>,
      );
      expect(v.charging, isFalse);
    });

    test('fromJson：明确 true 才算充电专属', () {
      final v = WhitelistVideo.fromJson({
        'bvid': 'BV1',
        'cid': 1,
        'charging': true,
      });
      expect(v.charging, isTrue);
    });

    test('fromJson：脏类型（字符串 "true" / 数字 1 / null / 对象）→ false（不误标）',
        () {
      for (final dirty in <dynamic>['true', 1, 0, null, {'x': 1}, []]) {
        final v = WhitelistVideo.fromJson({
          'bvid': 'BV1',
          'cid': 1,
          'charging': dirty,
        });
        expect(v.charging, isFalse, reason: '脏值 $dirty 不能被当成充电专属');
      }
    });

    test('toJson：只在为真时输出（false 一个字节都不多）', () {
      expect(_video().toJson().containsKey('charging'), isFalse);
      expect(_video(charging: true).toJson()['charging'], isTrue);
    });

    test('老数据零字节变化：视频级读进来再写回去，逐字节相同', () {
      final v = WhitelistVideo.fromJson(
        jsonDecode(_kOldVideoJson) as Map<String, dynamic>,
      );
      expect(jsonEncode(v.toJson()), _kOldVideoJson);
    });

    test('老数据零字节变化：整份 WhitelistData 读进来再写回去，逐字节相同', () {
      final data = WhitelistData.fromJson(
        jsonDecode(_kOldDataJson) as Map<String, dynamic>,
      );
      expect(data.videos.single.charging, isFalse);
      expect(jsonEncode(data.toJson()), _kOldDataJson);
    });

    test('charging = true 的视频往返后仍是 true，且 JSON 里只多这一个键', () {
      final v = _video(charging: true);
      final json = v.toJson();
      expect(json['charging'], isTrue);
      final back = WhitelistVideo.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(back.charging, isTrue);
      // 其余字段不受影响（新字段只加不改）
      expect(back.bvid, v.bvid);
      expect(back.title, v.title);
      expect(back.duration, v.duration);
    });

    test('copyWith：不传时透传；传 false 能把 true 改回去（UP 取消充电专属）', () {
      final charging = _video(charging: true);
      // 其它字段的 copyWith（如合集移动）不能把标记弄丢
      expect(charging.copyWith(collection: '动画').charging, isTrue);
      expect(charging.copyWith(order: 3).charging, isTrue);
      expect(charging.copyWith(desc: '新简介').charging, isTrue);
      // 双向：播放页拿到接口的 false 必须能盖掉旧真值
      expect(charging.copyWith(charging: false).charging, isFalse);
      // 不传 = 全等副本
      expect(charging.copyWith().charging, isTrue);
      expect(_video().copyWith(charging: true).charging, isTrue);
    });
  });

  group('parseViewCharging（view 接口 data.is_upower_exclusive）', () {
    test('实测形态：true → 充电专属；false → 普通视频', () {
      expect(parseViewCharging({'is_upower_exclusive': true}), isTrue);
      expect(parseViewCharging({'is_upower_exclusive': false}), isFalse);
    });

    test('容错：缺失 / 脏类型 / data 为 null → false（宁可漏标不误标）', () {
      expect(parseViewCharging(null), isFalse);
      expect(parseViewCharging(const {}), isFalse);
      expect(parseViewCharging({'is_upower_exclusive': 'true'}), isFalse);
      expect(parseViewCharging({'is_upower_exclusive': 1}), isFalse);
      expect(parseViewCharging({'is_upower_exclusive': null}), isFalse);
    });

    test('只看 is_upower_exclusive：is_upower_play / is_upower_preview 不参与判断',
        () {
      // 实测：充电视频在未充电账号下 is_upower_play 也是 false、
      // is_upower_preview 为 true；普通视频 is_upower_play 亦为 false。
      // 若误用这两个字段，就会把充电视频漏标成普通视频。
      expect(
        parseViewCharging({
          'is_upower_exclusive': true,
          'is_upower_play': false,
          'is_upower_preview': true,
        }),
        isTrue,
        reason: '充电视频（未充电账号）仍要认出是充电专属',
      );
      expect(
        parseViewCharging({'is_upower_play': false, 'is_upower_preview': false}),
        isFalse,
        reason: '普通视频只有这两个键时不能误标',
      );
    });
  });

  group('WhitelistWriter.videoFromMeta：入库时解析 charging', () {
    test('充电专属视频 → charging true，写 JSON 时带 charging:true', () {
      final meta = {
        'bvid': 'BV1A18cziEZt',
        'cid': 31235048595,
        'title': '充电专属',
        'pic': 'https://i0.hdslb.com/a.jpg',
        'duration': 70,
        'owner': {'name': '立米儿'},
        'is_upower_exclusive': true,
        'is_upower_play': false,
        'is_upower_preview': true,
      };
      final v = WhitelistWriter.videoFromMeta(meta,
          fallbackBvid: 'BV1A18cziEZt');
      expect(v.charging, isTrue);
      expect(v.toJson()['charging'], isTrue);
    });

    test('普通视频（字段为 false / 缺失）→ charging false，JSON 里不出现这个键',
        () {
      final explicitFalse = WhitelistWriter.videoFromMeta(
        {'bvid': 'BV1', 'cid': 1, 'title': 't', 'is_upower_exclusive': false},
        fallbackBvid: 'BV1',
      );
      expect(explicitFalse.charging, isFalse);
      expect(explicitFalse.toJson().containsKey('charging'), isFalse);

      final missing = WhitelistWriter.videoFromMeta(
        {'bvid': 'BV1', 'cid': 1, 'title': 't'},
        fallbackBvid: 'BV1',
      );
      expect(missing.charging, isFalse);
      expect(missing.toJson().containsKey('charging'), isFalse);
    });
  });
}
