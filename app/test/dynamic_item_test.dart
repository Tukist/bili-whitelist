// 动态模型宽松解析单测（v2.22.0+，UP 主主页「动态」区）：
// - 图文（DYNAMIC_TYPE_DRAW）：正文 / 配图（`//` 与 `http://` 归一化）/ 作者 / 时间
// - opus 形态（features=itemOpusStyle）：desc 为空 → 回退 opus.title + summary.text，
//   配图走 major.opus.pics[].url
// - 视频投稿（DYNAMIC_TYPE_AV）：major.archive 的 bvid/title/cover
// - 转发（DYNAMIC_TYPE_FORWARD）：orig 的原文署名与正文
// - 脏数据/缺字段一律给安全默认（不崩）
// - normalizeDynamicUrl 单测
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/dynamic_item.dart';

/// 一条动态的最小骨架（各用例往里塞 modules）。
Map<String, dynamic> _item({
  String id = '9001',
  String type = DynamicType.draw,
  String author = '测试UP',
  String face = '//i0.hdslb.com/bfs/face/x.jpg',
  int pubTs = 1700000000,
  Map<String, dynamic>? desc,
  Map<String, dynamic>? major,
  Map<String, dynamic>? orig,
}) =>
    {
      'id_str': id,
      'type': type,
      'modules': {
        'module_author': {'name': author, 'face': face, 'pub_ts': pubTs},
        'module_dynamic': {
          if (desc != null) 'desc': desc,
          if (major != null) 'major': major,
        },
      },
      if (orig != null) 'orig': orig,
    };

/// 转发的原文（同构：modules.module_author + module_dynamic.desc）。
Map<String, dynamic> _origItem({String author = '原PO', String text = '原文正文'}) =>
    {
      'id_str': '8001',
      'type': DynamicType.word,
      'modules': {
        'module_author': {'name': author, 'face': '', 'pub_ts': 1600000000},
        'module_dynamic': {
          'desc': {'text': text},
        },
      },
    };

void main() {
  group('DynamicItem.fromJson — 基础字段', () {
    test('id_str / type / 作者 / 时间 / 正文', () {
      final item = DynamicItem.fromJson(_item(
        id: '112233',
        type: DynamicType.draw,
        author: '老番茄',
        pubTs: 1730000000,
        desc: {'text': '今天的动态正文'},
      ));
      expect(item.id, '112233');
      expect(item.type, DynamicType.draw);
      expect(item.authorName, '老番茄');
      expect(item.pubTs, 1730000000);
      expect(item.text, '今天的动态正文');
      expect(item.hasText, isTrue);
      expect(item.isForward, isFalse);
      expect(item.hasVideo, isFalse);
      expect(item.hasImages, isFalse);
    });

    test('id_str 缺失 → 退回数字 id；两者都缺 → 空串', () {
      expect(
        DynamicItem.fromJson({
          'id': 12345,
          'type': DynamicType.word,
        }).id,
        '12345',
      );
      expect(DynamicItem.fromJson(const {}).id, '');
    });

    test('头像 `//` → https', () {
      final item = DynamicItem.fromJson(_item());
      expect(item.authorFace, 'https://i0.hdslb.com/bfs/face/x.jpg');
    });
  });

  group('DynamicItem.fromJson — 图文', () {
    test('draw：items[].src 收图并归一化（// 与 http://）', () {
      final item = DynamicItem.fromJson(_item(
        desc: {'text': '三张图'},
        major: {
          'draw': {
            'items': [
              {'src': '//i1.hdslb.com/a.jpg'},
              {'src': 'http://i2.hdslb.com/b.jpg'},
              {'src': 'https://i3.hdslb.com/c.jpg'},
            ],
          },
        },
      ));
      expect(item.imageUrls, [
        'https://i1.hdslb.com/a.jpg',
        'https://i2.hdslb.com/b.jpg',
        'https://i3.hdslb.com/c.jpg',
      ]);
      expect(item.hasImages, isTrue);
    });

    test('opus 形态：desc 为空 → 标题 + 摘要；pics[].url 收图', () {
      final item = DynamicItem.fromJson(_item(
        major: {
          'opus': {
            'title': '标题',
            'summary': {'text': '摘要正文'},
            'pics': [
              {'url': '//i0.hdslb.com/p1.jpg'},
            ],
          },
        },
      ));
      expect(item.text, '标题\n摘要正文');
      expect(item.imageUrls, ['https://i0.hdslb.com/p1.jpg']);
    });

    test('同一张图在 draw 与 opus 都出现 → 去重', () {
      final item = DynamicItem.fromJson(_item(
        desc: {'text': 'x'},
        major: {
          'draw': {
            'items': [
              {'src': '//i0.hdslb.com/same.jpg'},
            ],
          },
          'opus': {
            'pics': [
              {'url': '//i0.hdslb.com/same.jpg'},
            ],
          },
        },
      ));
      expect(item.imageUrls, ['https://i0.hdslb.com/same.jpg']);
    });

    test('空 src / 脏条目跳过，不产生空 URL', () {
      final item = DynamicItem.fromJson(_item(
        desc: {'text': 'x'},
        major: {
          'draw': {
            'items': [
              {'src': ''},
              'not-a-map',
              {'src': '//i0.hdslb.com/ok.jpg'},
            ],
          },
        },
      ));
      expect(item.imageUrls, ['https://i0.hdslb.com/ok.jpg']);
    });
  });

  group('DynamicItem.fromJson — 视频投稿', () {
    test('archive：bvid / title / cover（cover 归一化）', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.av,
        desc: {'text': '投了个视频'},
        major: {
          'archive': {
            'bvid': 'BV1xx411c7mD',
            'title': '视频标题',
            'cover': '//i0.hdslb.com/cover.jpg',
          },
        },
      ));
      expect(item.hasVideo, isTrue);
      expect(item.videoBvid, 'BV1xx411c7mD');
      expect(item.videoTitle, '视频标题');
      expect(item.videoCover, 'https://i0.hdslb.com/cover.jpg');
    });

    test('archive 缺字段 → 空值收敛成 null（封面/标题/投稿都算没有）', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.av,
        major: {
          'archive': {'bvid': '', 'title': '', 'cover': ''},
        },
      ));
      expect(item.hasVideo, isFalse);
      expect(item.videoBvid, isNull);
      expect(item.videoTitle, isNull);
      expect(item.videoCover, isNull);
    });

    test('非 AV 类型没有 archive → 视频字段全 null', () {
      final item = DynamicItem.fromJson(_item(desc: {'text': '纯文字'}));
      expect(item.hasVideo, isFalse);
      expect(item.videoCover, isNull);
    });
  });

  group('DynamicItem.fromJson — 转发', () {
    test('orig 的作者与正文被抽出，isForward 为真', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': '转发附言'},
        orig: _origItem(author: '原作者', text: '被转发的原文'),
      ));
      expect(item.isForward, isTrue);
      expect(item.text, '转发附言');
      expect(item.origAuthor, '原作者');
      expect(item.origText, '被转发的原文');
    });

    test('转发但原文被删（orig 缺/空）→ origText 与 origAuthor 均 null，'
        'isForward 仍由 type 判定', () {
      final missing = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': '转了个已删除的'},
      ));
      expect(missing.origText, isNull);
      expect(missing.origAuthor, isNull);
      expect(missing.isForward, isTrue);

      final empty = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': 'x'},
        orig: _origItem(author: '', text: ''),
      ));
      expect(empty.origText, isNull);
      expect(empty.origAuthor, isNull);
    });

    test('type 缺失但 orig 完整（异常响应）→ 兼容视为转发', () {
      final item = DynamicItem.fromJson(_item(
        type: '',
        desc: {'text': 'x'},
        orig: _origItem(),
      ));
      expect(item.isForward, isTrue);
      expect(item.origText, '原文正文');
    });
  });

  group('DynamicItem.fromJson — 脏数据不崩', () {
    test('空 JSON → 全部安全默认', () {
      final item = DynamicItem.fromJson(const {});
      expect(item.id, '');
      expect(item.type, '');
      expect(item.pubTs, 0);
      expect(item.authorName, '');
      expect(item.authorFace, '');
      expect(item.text, '');
      expect(item.imageUrls, isEmpty);
      expect(item.videoBvid, isNull);
      expect(item.videoTitle, isNull);
      expect(item.videoCover, isNull);
      expect(item.origText, isNull);
      expect(item.origAuthor, isNull);
      expect(item.isForward, isFalse);
      expect(item.hasText, isFalse);
    });

    test('字段类型全乱（modules 不是 Map / 数字当字符串）不崩', () {
      final item = DynamicItem.fromJson({
        'id_str': 123,
        'type': 7,
        'modules': 'not-a-map',
        'orig': 42,
      });
      expect(item.id, ''); // id_str 非字符串 → 视作缺失
      expect(item.type, '');
      expect(item.pubTs, 0);
      expect(item.isForward, isFalse);
    });

    test('pub_ts 缺失 → 0（UI 不显示时间）', () {
      final item = DynamicItem.fromJson({
        'id_str': '1',
        'modules': {
          'module_author': {'name': 'x'},
          'module_dynamic': {
            'desc': {'text': 'y'},
          },
        },
      });
      expect(item.pubTs, 0);
      expect(item.text, 'y');
    });
  });

  group('DynamicPage / normalizeDynamicUrl', () {
    test('DynamicPage.empty 与默认字段', () {
      expect(DynamicPage.empty.isEmpty, isTrue);
      expect(DynamicPage.empty.nextOffset, '');
      expect(DynamicPage.empty.hasMore, isFalse);
      const page = DynamicPage(items: []);
      expect(page.hasMore, isFalse);
    });

    test('normalizeDynamicUrl：// → https、http → https、其余原样', () {
      expect(normalizeDynamicUrl('//i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(normalizeDynamicUrl('http://i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(normalizeDynamicUrl('https://i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(normalizeDynamicUrl(''), '');
    });
  });
}
