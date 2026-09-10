// UiCopyStore 单元测试（lib/services/ui_copy_store.dart）：
// - 出厂默认逐字读取（含测试断言的锚点文案）
// - 覆盖生效 / 空串等价于清除 / 未知 id 原样返回
// - resetAll 回到默认
// - 持久化：写盘后重新读盘（模拟重启）能读回覆盖
// - 损坏数据（非 JSON / 非对象 / 非字符串值 / 空值）容错
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/ui_copy_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UiCopyStore.instance.resetForTest();
    await UiCopyStore.instance.ensureLoaded();
  });

  group('出厂默认', () {
    test('测试断言锚点文案逐字一致（改一个字这些断言就红）', () {
      final store = UiCopyStore.instance;
      expect(store.text('empty.history'), '暂无历史记录');
      expect(store.text('empty.daily_history'), '该日无观看记录');
      expect(store.text('empty.watch_heat'), '开始观看后这里会生成你的观看热力');
      expect(store.text('empty.favorites'),
          '还没有收藏夹。\n在 B 站收藏想看的视频后，这里就能直接点开看');
      expect(store.text('empty.playlist'), '白名单为空\n下拉刷新重新同步');
      expect(store.text('empty.playlist.upowner'), '还没有白名单 UP 主');
      expect(store.text('empty.collection'), '暂无合集');
      expect(store.text('empty.comment'), '暂无评论');
      expect(store.text('empty.cache'), '暂无缓存');
      expect(store.text('empty.followings'),
          '这个账号还没有关注任何 UP 主\n（或关注列表未公开）');
      expect(store.text('empty.upowner_videos'), '暂无视频');
      expect(store.text('empty.upowner.season'), '该合集暂无视频');
      expect(store.text('empty.upowner.list'), '该列表暂无视频');
      expect(store.text('footer.no_more'), '没有更多了');
    });

    test('副文案（.sub）与加载/错误默认齐全', () {
      final store = UiCopyStore.instance;
      expect(store.text('empty.history.sub'), '看过的视频会出现在这里，点击可续播');
      expect(store.text('empty.watch_heat.sub'),
          '播放时按真实播放秒数累计（缓冲/跳转不计），按天本地保存');
      expect(store.text('loading.generic'), isNotEmpty);
      expect(store.text('error.generic'), isNotEmpty);
    });

    test('每个 .sub 都有对应的主 id（命名约定自洽）', () {
      for (final id in UiCopyStore.kDefaultCopies.keys) {
        if (!id.endsWith('.sub')) continue;
        final main = id.substring(0, id.length - 4);
        expect(
          UiCopyStore.kDefaultCopies.containsKey(main),
          isTrue,
          reason: '$id 找不到主 id $main',
        );
      }
    });

    test('未覆盖时 hasOverride 为 false', () {
      expect(UiCopyStore.instance.hasOverride('empty.history'), isFalse);
    });
  });

  group('覆盖', () {
    test('setOverride 后 text 立刻返回覆盖值（同步生效）', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '这里空得能听见回声');
      expect(store.text('empty.history'), '这里空得能听见回声');
      expect(store.hasOverride('empty.history'), isTrue);
    });

    test('覆盖只影响自己那条，其他仍走默认', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '改了');
      expect(store.text('empty.daily_history'), '该日无观看记录');
    });

    test('覆盖值首尾空白被裁剪', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.comment', '  安静  ');
      expect(store.text('empty.comment'), '安静');
    });

    test('setOverride 空串 = 清除该条覆盖，回到默认', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '改了');
      await store.setOverride('empty.history', '   ');
      expect(store.text('empty.history'), '暂无历史记录');
      expect(store.hasOverride('empty.history'), isFalse);
    });

    test('clearOverride 单独清除（不存在的 id 无副作用）', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.cache', '空');
      await store.clearOverride('empty.cache');
      expect(store.text('empty.cache'), '暂无缓存');
      await store.clearOverride('不存在的 id'); // 不抛
    });

    test('未知 id 原样返回（漏配的 id 在界面上显形）', () {
      expect(UiCopyStore.instance.text('nope.unknown'), 'nope.unknown');
    });

    test('resetAll 清空全部覆盖', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', 'A');
      await store.setOverride('empty.comment', 'B');
      await store.resetAll();
      expect(store.text('empty.history'), '暂无历史记录');
      expect(store.text('empty.comment'), '暂无评论');
      expect(store.hasOverride('empty.history'), isFalse);
    });
  });

  group('持久化', () {
    test('setOverride 写盘：重新读盘（模拟重启）能读回', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.inbox', '没有新视频，休息一下');

      // resetForTest() 不传参 → 内存覆盖清空 + _loaded=false（尚未读盘）
      store.resetForTest();
      expect(store.text('empty.inbox'),
          '暂未有白名单 UP 主的新视频\n在「搜索」→「搜索 UP 主」中加入 UP 主后，\nTA 发布的新视频会出现在这里');

      await store.ensureLoaded();
      expect(store.text('empty.inbox'), '没有新视频，休息一下');
    });

    test('写盘内容是 JSON 对象，只含被改过的 id', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '改了历史');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(UiCopyStore.storageKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded.keys.toList(), ['empty.history']);
      expect(decoded['empty.history'], '改了历史');
    });

    test('resetAll 会删掉存储 key', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '改了历史');
      await store.resetAll();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UiCopyStore.storageKey), isNull);
    });

    test('ensureLoaded 重复调用只读一次盘，且不覆盖内存态', () async {
      final store = UiCopyStore.instance;
      await store.setOverride('empty.history', '内存里的');
      // 直接改盘上的内容，模拟「外部把存储改脏」
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        UiCopyStore.storageKey,
        jsonEncode({'empty.history': '盘上的'}),
      );
      await store.ensureLoaded(); // 已加载过 → 不再读盘
      expect(store.text('empty.history'), '内存里的');
    });
  });

  group('损坏数据容错', () {
    Future<void> seed(String raw) async {
      SharedPreferences.setMockInitialValues({UiCopyStore.storageKey: raw});
      UiCopyStore.instance.resetForTest();
      await UiCopyStore.instance.ensureLoaded();
    }

    test('非 JSON → 全部走默认，不抛', () async {
      await seed('这不是 JSON{{{');
      expect(UiCopyStore.instance.text('empty.history'), '暂无历史记录');
    });

    test('非对象（数组 / 字符串）→ 全部走默认', () async {
      await seed('["a","b"]');
      expect(UiCopyStore.instance.text('empty.history'), '暂无历史记录');
      await seed('"纯字符串"');
      expect(UiCopyStore.instance.text('empty.history'), '暂无历史记录');
    });

    test('非字符串值 / 空 id / 空文案 一律丢弃', () async {
      await seed(jsonEncode({
        'empty.history': '保留我',
        'empty.comment': 42,
        '   ': '无 id',
        'empty.cache': '   ',
      }));
      expect(UiCopyStore.instance.text('empty.history'), '保留我');
      expect(UiCopyStore.instance.text('empty.comment'), '暂无评论');
      expect(UiCopyStore.instance.text('empty.cache'), '暂无缓存');
    });

    test('空字符串存储 → 全部走默认', () async {
      await seed('');
      expect(UiCopyStore.instance.text('empty.history'), '暂无历史记录');
    });
  });

  group('resetForTest', () {
    test('传 map → 当作内存覆盖且不被随后读盘冲掉', () async {
      SharedPreferences.setMockInitialValues({
        UiCopyStore.storageKey: jsonEncode({'empty.history': '盘上的'}),
      });
      final store = UiCopyStore.instance;
      store.resetForTest({'empty.history': '内存里的'});
      expect(store.text('empty.history'), '内存里的');
      await store.ensureLoaded(); // 已标记 loaded → 不读盘
      expect(store.text('empty.history'), '内存里的');
    });
  });
}
