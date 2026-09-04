// 评论区模型纯函数/解析单测：
// - decodeCommentMessage：`<br />` 转行 / HTML 实体 / 数字实体 / 残留标签剥离
// - CommentPicture.fromJson：http(s) 归一 / 尺寸 / 动图标记
// - CommentReply.fromJson：字段 / 图片 / 楼中楼预览（嵌套不递归）
// - resolveAidForVideo：meta 带 aid / 缺失 / 脏类型
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/comment.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1test',
      cid: 1,
      title: 't',
      cover: '',
      duration: 0,
      upName: 'u',
      addedAt: '',
    );

Map<String, dynamic> _replyJson({
  required int rpid,
  int root = 0,
  int parent = 0,
  int count = 0,
  int like = 7,
  int ctime = 1700000000,
  String uname = '路人',
  String avatar = 'http://i0.hdslb.com/bfs/face/a.jpg',
  int level = 3,
  String message = '前排',
  List<Map<String, dynamic>>? pictures,
  List<Map<String, dynamic>>? nested,
}) =>
    {
      'rpid': rpid,
      'root': root,
      'parent': parent,
      'count': count,
      'like': like,
      'ctime': ctime,
      'member': {
        'uname': uname,
        'avatar': avatar,
        'level_info': {'current_level': level},
      },
      'content': {
        'message': message,
        if (pictures != null) 'pictures': pictures,
      },
      if (nested != null) 'replies': nested,
    };

void main() {
  group('decodeCommentMessage', () {
    test('`<br />`/`<br>`/`<br/>` → 换行', () {
      expect(decodeCommentMessage('第一行<br />第二行'), '第一行\n第二行');
      expect(decodeCommentMessage('a<br>b<br/>c'), 'a\nb\nc');
      expect(decodeCommentMessage('a<br  >b'), 'a\nb');
    });

    test('常见 HTML 实体解码', () {
      expect(
        decodeCommentMessage('a&amp;b &lt;tag&gt; &quot;q&quot; &#39;x&#39;'),
        'a&b <tag> "q" \'x\'',
      );
      expect(decodeCommentMessage('&apos;y&apos; &nbsp;z'), '\'y\'  z');
    });

    test('数字实体（十进制 / 十六进制）解码', () {
      expect(decodeCommentMessage('&#22909;&#x597d;'), '好好');
      expect(decodeCommentMessage('&#x1F600;'), '\u{1F600}');
    });

    test('残留 HTML 标签壳剥离', () {
      expect(decodeCommentMessage('a<span class="x">b</span>c'), 'abc');
    });

    test('空串 / 无特殊内容原样', () {
      expect(decodeCommentMessage(''), '');
      expect(decodeCommentMessage('普通内容'), '普通内容');
    });
  });

  group('CommentPicture.fromJson', () {
    test('http → https、`//` 补协议、尺寸与动图标记', () {
      final p1 = CommentPicture.fromJson({
        'img_src': 'http://i0.hdslb.com/bfs/comment/x.jpg',
        'img_width': 640,
        'img_height': 480,
        'play_gif_thumbnail': true,
      });
      expect(p1.imgSrc, 'https://i0.hdslb.com/bfs/comment/x.jpg');
      expect(p1.width, 640);
      expect(p1.height, 480);
      expect(p1.isGif, isTrue);

      final p2 = CommentPicture.fromJson({
        'img_src': '//i1.hdslb.com/bfs/comment/y.webp',
        'img_width': 100,
        'img_height': 200,
      });
      expect(p2.imgSrc, 'https://i1.hdslb.com/bfs/comment/y.webp');
      expect(p2.isGif, isFalse);
      expect(p2.width, 100);
      expect(p2.height, 200);
    });

    test('字段缺失/脏类型兜底不崩', () {
      final p = CommentPicture.fromJson({'img_src': ''});
      expect(p.imgSrc, '');
      expect(p.width, 0);
      expect(p.height, 0);
      expect(p.isGif, isFalse);
    });
  });

  group('CommentReply.fromJson', () {
    test('基础字段解析（member/content/ctime）', () {
      final r = CommentReply.fromJson(_replyJson(
        rpid: 1001,
        root: 0,
        parent: 0,
        count: 42,
        like: 99,
        ctime: 1700000000,
        uname: '测试君',
        level: 6,
        message: '内容<br />换行',
      ));
      expect(r.rpid, 1001);
      expect(r.isRoot, isTrue);
      expect(r.count, 42);
      expect(r.like, 99);
      expect(r.ctime, 1700000000);
      expect(r.uname, '测试君');
      expect(r.level, 6);
      expect(r.avatar, 'https://i0.hdslb.com/bfs/face/a.jpg');
      expect(r.message, '内容\n换行');
      expect(r.pictures, isEmpty);
      expect(r.previews, isEmpty);
    });

    test('图片评论解析', () {
      final r = CommentReply.fromJson(_replyJson(
        rpid: 1,
        pictures: [
          {
            'img_src': 'http://i0.hdslb.com/bfs/comment/1.jpg',
            'img_width': 100,
            'img_height': 50,
          },
          {
            'img_src': '//i0.hdslb.com/bfs/comment/2.gif',
            'img_width': 50,
            'img_height': 100,
            'play_gif_thumbnail': true,
          },
        ],
      ));
      expect(r.pictures, hasLength(2));
      expect(r.pictures[0].imgSrc, 'https://i0.hdslb.com/bfs/comment/1.jpg');
      expect(r.pictures[0].width, 100);
      expect(r.pictures[1].isGif, isTrue);
    });

    test('楼中楼预览解析（至多保留嵌套一层，不再递归）', () {
      final deep = _replyJson(rpid: 2003, nested: [
        // 预览子条自己又带 replies —— 浅解析应忽略（防无限展开）
        _replyJson(rpid: 3001, message: '子回复带嵌套', nested: [
          _replyJson(rpid: 4001, message: '深层嵌套'),
        ]),
      ]);
      final r = CommentReply.fromJson(_replyJson(
        rpid: 1001,
        count: 5,
        nested: [
          _replyJson(rpid: 2001, message: '第一条预览'),
          _replyJson(rpid: 2002, message: '第二条预览'),
          deep,
        ],
      ));
      expect(r.previews, hasLength(3));
      expect(r.previews[0].message, '第一条预览');
      // 预览条目的 previews 不解析（浅解析），防嵌套膨胀
      expect(r.previews[0].previews, isEmpty);
      expect(r.previews[2].previews, isEmpty);
      // 预览条目保留基本字段（可显示头像/名字/等级）
      expect(r.previews[2].rpid, 2003);
      expect(r.previews[2].level, 3);
    });

    test('缺 member/content 的脏数据不崩', () {
      final r = CommentReply.fromJson({'rpid': 1});
      expect(r.rpid, 1);
      expect(r.uname, '');
      expect(r.message, '');
      expect(r.previews, isEmpty);
    });
  });

  group('resolveAidForVideo', () {
    test('meta 带 aid → 直接用', () {
      expect(resolveAidForVideo(_video(), meta: {'aid': 170001}), 170001);
    });

    test('无 meta / meta 缺 aid / 非数字 aid → null（需异步 view 补）', () {
      expect(resolveAidForVideo(_video()), isNull);
      expect(resolveAidForVideo(_video(), meta: {}), isNull);
      expect(resolveAidForVideo(_video(), meta: {'aid': 0}), isNull);
      expect(
        resolveAidForVideo(_video(), meta: {'aid': 'BVxxx'}),
        isNull,
      );
    });
  });
}
