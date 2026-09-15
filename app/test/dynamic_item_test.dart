// 动态模型宽松解析单测（v2.22.0+，UP 主主页「动态」区）：
// - 图文（DYNAMIC_TYPE_DRAW）：正文 / 配图（`//` 与 `http://` 归一化）/ 作者 / 时间
// - opus 形态（features=itemOpusStyle）：desc 为空 → 回退 opus.title + summary.text，
//   配图走 major.opus.pics[].url
// - 视频投稿（DYNAMIC_TYPE_AV）：major.archive 的 bvid/title/cover
// - 转发（DYNAMIC_TYPE_FORWARD）：orig 的原文署名与正文
// - **转发原文的图片/视频**（v2.31.0+，详情页要完整还原原文）
// - **互动数据 module_stat**（v2.31.0+）：like/comment/forward 的 count
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

/// 转发的原文（同构：modules.module_author + module_dynamic.desc | major）。
Map<String, dynamic> _origItem({
  String author = '原PO',
  String text = '原文正文',
  Map<String, dynamic>? major,
}) =>
    {
      'id_str': '8001',
      'type': DynamicType.word,
      'modules': {
        'module_author': {'name': author, 'face': '', 'pub_ts': 1600000000},
        'module_dynamic': {
          'desc': {'text': text},
          if (major != null) 'major': major,
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

  group('DynamicItem.fromJson — 互动数据（module_stat，v2.31.0+）', () {
    test('like / comment / forward 三个 count 都取到', () {
      final item = DynamicItem.fromJson({
        ..._item(desc: {'text': 'x'}),
        'modules': {
          'module_author': {'name': 'x', 'pub_ts': 1},
          'module_dynamic': {
            'desc': {'text': 'x'},
          },
          // 结构照抄线上（键名与服务端同名）
          'module_stat': {
            'comment': {'count': 34, 'forbidden': false},
            'forward': {'count': 2, 'forbidden': false},
            'like': {'count': 65, 'forbidden': false, 'status': true},
          },
        },
      });
      expect(item.stat.like, 65);
      expect(item.stat.comment, 34);
      expect(item.stat.forward, 2);
      expect(item.stat.isEmpty, isFalse);
    });

    test('缺 module_stat / 缺子对象 / count 脏类型 → 一律 0（不崩）', () {
      expect(DynamicItem.fromJson(_item(desc: {'text': 'x'})).stat.isEmpty, isTrue);

      final dirty = DynamicItem.fromJson({
        'id_str': '1',
        'modules': {
          'module_stat': {
            'like': 'not-a-map',
            'comment': {'count': '12'}, // 数字串容错
            'forward': {'count': true}, // 布尔 → 0
          },
        },
      });
      expect(dirty.stat.like, 0);
      expect(dirty.stat.comment, 12);
      expect(dirty.stat.forward, 0);
      expect(dirty.stat.isEmpty, isFalse, reason: '评论数非 0 就不是空');
    });

    test('DynamicStat.empty 与显式构造', () {
      expect(DynamicStat.empty.isEmpty, isTrue);
      const stat = DynamicStat(like: 1);
      expect(stat.isEmpty, isFalse);
      expect(stat.comment, 0);
      expect(stat.forward, 0);
    });
  });

  group('DynamicItem.fromJson — 转发原文的图片/视频（v2.31.0+）', () {
    test('原文带图：origImageUrls 收图并归一化', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': '转发附言'},
        orig: _origItem(
          text: '原文正文',
          major: {
            'draw': {
              'items': [
                {'src': '//i0.hdslb.com/o1.jpg'},
              ],
            },
          },
        ),
      ));
      expect(item.origHasImages, isTrue);
      expect(item.origImageUrls, ['https://i0.hdslb.com/o1.jpg']);
      // 本条动态自己没有图（原文的图不该混进主图集）
      expect(item.imageUrls, isEmpty);
    });

    test('原文带视频投稿：origVideoBvid/Title/Cover 取到', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': '转发附言'},
        orig: _origItem(
          major: {
            'archive': {
              'bvid': 'BV1orig1111',
              'title': '原文里的视频',
              'cover': '//i0.hdslb.com/oc.jpg',
            },
          },
        ),
      ));
      expect(item.origHasVideo, isTrue);
      expect(item.origVideoBvid, 'BV1orig1111');
      expect(item.origVideoTitle, '原文里的视频');
      expect(item.origVideoCover, 'https://i0.hdslb.com/oc.jpg');
      expect(item.hasVideo, isFalse, reason: '不是本条动态自己的投稿');
    });

    test('原文是 opus 形态：pics 收图、正文回退 title + summary', () {
      final item = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': '转发附言'},
        orig: {
          'id_str': '8002',
          'modules': {
            'module_author': {'name': '原PO'},
            'module_dynamic': {
              'major': {
                'opus': {
                  'title': '原文标题',
                  'summary': {'text': '原文摘要'},
                  'pics': [
                    {'url': '//i0.hdslb.com/op.jpg'},
                  ],
                },
              },
            },
          },
        },
      ));
      expect(item.origText, '原文标题\n原文摘要');
      expect(item.origImageUrls, ['https://i0.hdslb.com/op.jpg']);
    });

    test('非转发 / 原文已删 → 原文媒体全空（不崩）', () {
      final plain = DynamicItem.fromJson(_item(desc: {'text': 'x'}));
      expect(plain.origImageUrls, isEmpty);
      expect(plain.origVideoBvid, isNull);
      expect(plain.origHasImages, isFalse);
      expect(plain.origHasVideo, isFalse);

      final deleted = DynamicItem.fromJson(_item(
        type: DynamicType.forward,
        desc: {'text': 'x'},
      ));
      expect(deleted.origImageUrls, isEmpty);
      expect(deleted.origVideoCover, isNull);
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
      expect(item.origImageUrls, isEmpty);
      expect(item.origVideoBvid, isNull);
      expect(item.origVideoTitle, isNull);
      expect(item.origVideoCover, isNull);
      expect(item.stat.isEmpty, isTrue);
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

  group('DynamicItem.fromJson — 评论归属 basic（v2.31.0+）', () {
    test('comment_type/comment_id_str 原样取出（相册型动态的真实取值）', () {
      final item = DynamicItem.fromJson({
        ..._item(desc: {'text': 'x'}),
        'basic': {
          'comment_type': 11,
          'comment_id_str': '326122895',
          'rid_str': '326122895',
        },
      });
      expect(item.commentType, 11);
      expect(item.commentId, '326122895');
    });

    test('没有 comment_id_str → 回退 rid_str；两者都缺 → 空串 / 0', () {
      expect(
        DynamicItem.fromJson({
          'id_str': '1',
          'basic': {'comment_type': 17, 'rid_str': '999'},
        }).commentId,
        '999',
      );
      final none = DynamicItem.fromJson(_item(desc: {'text': 'x'}));
      expect(none.commentType, 0);
      expect(none.commentId, '');
      expect(DynamicItem.fromJson(const {}).commentType, 0);
    });

    test('basic 脏类型（不是 Map / 字段类型乱）→ 安全默认', () {
      final item = DynamicItem.fromJson({
        'id_str': '1',
        'basic': 'not-a-map',
      });
      expect(item.commentType, 0);
      expect(item.commentId, '');

      final dirty = DynamicItem.fromJson({
        'id_str': '1',
        'basic': {'comment_type': '11', 'comment_id_str': 326122895},
      });
      expect(dirty.commentType, 11, reason: '数字串容错');
      expect(dirty.commentId, '', reason: '非字符串 id 按缺失处理');
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
