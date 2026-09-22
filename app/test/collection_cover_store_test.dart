// 本机合集封面存储（v2.50.0）单元测试。
//
// 覆盖的是这一版最容易出错、也最难肉眼发现的部分：
// - **写 / 读**：图片真的落进 `<root>/collection_covers/`，映射能按合集路径读回；
// - **回落**：没有映射 → null；映射在但文件没了 → null（卡片据此回落 Gist URL，
//   而不是画一块空白）；
// - **元数据搬迁**（合集身份 = 路径字符串，改路径就必须搬 key）：
//   rename（自己 + 子孙）、move（嵌套到别的合集 / 移回顶层）、
//   删除（自己的丢掉、子孙上提一级）；
// - **不留孤儿**：换新图删旧文件；删合集连文件一起清；
// - **落盘**：换一次「进程」（reset + ensureLoaded）映射还在。
//
// 用临时目录作根目录（注入 [CollectionCoverStore.rootDirOverride]），不依赖
// path_provider 原生插件 —— 与 download_manager_test / update_service_test
// 同一条路子。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/collection_cover_store.dart';

/// 1×1 的合法 PNG（合成图，不涉任何用户数据）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

late Directory _tmp;

/// 「换一次进程」：清内存态 + 重新指定根目录 + 重新加载（测试里唯一的入口）。
Future<CollectionCoverStore> _freshStore() async {
  final store = CollectionCoverStore.instance;
  store.resetForTest();
  store.rootDirOverride = _tmp;
  await store.ensureLoaded();
  return store;
}

/// 存储里那张表的**原始 JSON**（断言真的落了盘，而不是只在内存里）。
Map<String, dynamic> _savedMapping(SharedPreferences prefs) {
  final raw = prefs.getString(CollectionCoverStore.storageKey);
  if (raw == null) return {};
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

/// 让 `unawaited(_persist())`（同步方法后台落盘）跑完 —— 纯 Dart 的 `test`
/// 里真实异步是正常转的，给一轮事件循环就够。
Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _tmp = Directory.systemTemp.createTempSync('cover_store_test');
  });

  tearDown(() {
    CollectionCoverStore.instance.resetForTest();
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('写 / 读', () {
    test('存一张本机封面：文件落在 collection_covers/ 下，按路径能读回来', () async {
      final store = await _freshStore();

      final name = await store.saveLocalCover('动画', _png, fileName: 'IMG_1.PNG');

      expect(name, isNotNull);
      expect(name, endsWith('.png'), reason: '扩展名取相册给的文件名（小写归一）');
      final path = store.localCoverPath('动画');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue, reason: '图片真的写进磁盘了');
      expect(File(path).readAsBytesSync(), _png);
      expect(
        path.replaceAll(r'\', '/'),
        contains('/${CollectionCoverStore.dirName}/'),
        reason: '图片放在 App 私有目录的 collection_covers/ 子目录',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(_savedMapping(prefs)['动画'], name, reason: '映射落盘（key = 合集路径）');
    });

    test('路径先规范化：` 动画 / 2024冬 ` 与 `动画/2024冬` 是同一张封面', () async {
      final store = await _freshStore();
      await store.saveLocalCover(' 动画 / 2024冬 ', _png);

      expect(store.localCoverPath('动画/2024冬'), isNotNull);
      expect(store.localCoverPath(' 动画 / 2024冬 '), isNotNull);
      // 脏路径（空段）也归一化：`动画//2024冬` 与 `动画/2024冬` 同一个 key
      expect(store.localCoverPath('动画//2024冬'), isNotNull);
    });

    test('没有映射 → null；空路径 → null', () async {
      final store = await _freshStore();
      expect(store.localCoverPath('动画'), isNull);
      expect(store.localCoverPath(''), isNull);
      expect(store.debugMapping, isEmpty);
    });

    test('映射在但文件没了 → null（卡片据此回落 Gist cover）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      final path = store.localCoverPath('动画');
      expect(path, isNotNull, reason: '前提：先有本机封面');

      File(path!).deleteSync(); // 用户清了 App 数据 / 手动删了文件

      expect(store.localCoverPath('动画'), isNull,
          reason: '文件不在就不该再报路径（否则 Image.file 画出一块空白）');
    });

    test('换一张新图：旧文件被删掉（不留孤儿）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      final first = store.localCoverPath('动画')!;

      await store.saveLocalCover('动画', Uint8List.fromList([..._png, 0]));

      final second = store.localCoverPath('动画')!;
      expect(second, isNot(first));
      expect(File(second).existsSync(), isTrue);
      expect(File(first).existsSync(), isFalse, reason: '旧文件没人引用了，删掉');
    });

    test('空字节 / 空路径不写（返回 null，调用方按"没存上"处理）', () async {
      final store = await _freshStore();
      expect(await store.saveLocalCover('动画', Uint8List(0)), isNull);
      expect(await store.saveLocalCover('', _png), isNull);
      expect(store.debugMapping, isEmpty);
    });

    test('扩展名不认识 / 没有扩展名 → .jpg（文件名只为看图工具友好）', () async {
      final store = await _freshStore();
      expect(await store.saveLocalCover('甲', _png, fileName: 'a.tiff'),
          endsWith('.jpg'));
      expect(await store.saveLocalCover('乙', _png, fileName: 'IMG_2'), endsWith('.jpg'));
      expect(await store.saveLocalCover('丙', _png, fileName: 'IMG.3.webp'),
          endsWith('.webp'));
    });
  });

  group('移除 / 删除', () {
    test('removeLocalCover：映射与文件一起清掉', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      final path = store.localCoverPath('动画')!;

      store.removeLocalCover('动画');
      await _drain();

      expect(store.localCoverPath('动画'), isNull);
      expect(File(path).existsSync(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(_savedMapping(prefs), isEmpty);
    });

    test('移除不存在的封面：什么都不做，不抛', () async {
      final store = await _freshStore();
      store.removeLocalCover('不存在');
      await _drain();
      expect(store.localCoverPath('不存在'), isNull);
    });
  });

  group('元数据搬迁（改路径 = 必须搬 key）', () {
    test('rename：自己与子孙的映射一起换前缀', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      await store.saveLocalCover('动画/2024冬', _png);
      await store.saveLocalCover('动画/2024冬/OVA', _png);
      await store.saveLocalCover('音乐', _png);
      final musicPath = store.localCoverPath('音乐');

      store.rebaseLocalCovers('动画', '番剧');

      expect(store.localCoverPath('番剧'), isNotNull);
      expect(store.localCoverPath('番剧/2024冬'), isNotNull);
      expect(store.localCoverPath('番剧/2024冬/OVA'), isNotNull);
      expect(store.localCoverPath('动画'), isNull, reason: '旧路径不再有映射');
      expect(store.localCoverPath('动画/2024冬'), isNull);
      expect(store.localCoverPath('音乐'), musicPath, reason: '无关合集不受影响');
      // 文件没动（只换 key），所以封面内容一模一样
      expect(File(store.localCoverPath('番剧')!).readAsBytesSync(), _png);

      // 搬迁也要落盘（换设备/重启后不丢）：方法是同步的，等一轮事件循环
      await _drain();
      final prefs = await SharedPreferences.getInstance();
      expect(_savedMapping(prefs)['番剧'], isNotNull);
      expect(_savedMapping(prefs).containsKey('动画'), isFalse);
    });

    test('move：嵌套到别的合集下面（前缀换成 音乐/动画）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      await store.saveLocalCover('动画/2024冬', _png);

      store.rebaseLocalCovers('动画', '音乐/动画');

      expect(store.localCoverPath('音乐/动画'), isNotNull);
      expect(store.localCoverPath('音乐/动画/2024冬'), isNotNull);
      expect(store.localCoverPath('动画'), isNull);
    });

    test('move：移回顶层（前缀收窄，`音乐/动画/2024冬` → `动画/2024冬`）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('音乐/动画', _png);
      await store.saveLocalCover('音乐/动画/2024冬', _png);

      store.rebaseLocalCovers('音乐/动画', '动画');

      expect(store.localCoverPath('动画'), isNotNull);
      expect(store.localCoverPath('动画/2024冬'), isNotNull);
      expect(store.localCoverPath('音乐/动画'), isNull);
    });

    test('删除合集：自己那张丢掉、子孙上提一级（includeSelf=false）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      await store.saveLocalCover('动画/2024冬', _png);
      await store.saveLocalCover('动画/2024冬/OVA', _png);
      final animePath = store.localCoverPath('动画')!;

      // 页面层删除合集时就是这两步（先清自己，再搬子孙）
      store.removeLocalCover('动画');
      store.rebaseLocalCovers('动画', '', includeSelf: false);
      await _drain();

      expect(store.localCoverPath('动画'), isNull);
      expect(File(animePath).existsSync(), isFalse, reason: '被删合集的图不留孤儿');
      expect(store.localCoverPath('2024冬'), isNotNull, reason: '子孙上提一级');
      expect(store.localCoverPath('2024冬/OVA'), isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(_savedMapping(prefs).keys, ['2024冬', '2024冬/OVA']);
    });

    test('没有命中任何映射时不动存储（不产生无谓写入）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('音乐', _png);
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString(CollectionCoverStore.storageKey);

      store.rebaseLocalCovers('动画', '番剧');
      await _drain();

      expect(prefs.getString(CollectionCoverStore.storageKey), before);
    });

    test('前缀相似但不是子孙的路径不受影响（`动画2` 不该被 `动画` 搬走）', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      await store.saveLocalCover('动画2', _png);

      store.rebaseLocalCovers('动画', '番剧');

      expect(store.localCoverPath('番剧'), isNotNull);
      expect(store.localCoverPath('动画2'), isNotNull);
      expect(store.localCoverPath('番剧2'), isNull);
    });
  });

  group('落盘 / 脏数据', () {
    test('换一次「进程」（reset + ensureLoaded）映射还在', () async {
      final store = await _freshStore();
      await store.saveLocalCover('动画', _png);
      final path = store.localCoverPath('动画');

      final again = await _freshStore();

      expect(again.localCoverPath('动画'), path, reason: '映射与文件名都从 prefs 读回来');
    });

    test('prefs 里是垃圾字符串 → 当空表处理，不崩', () async {
      SharedPreferences.setMockInitialValues({
        CollectionCoverStore.storageKey: '这不是 JSON',
      });
      final store = await _freshStore();
      expect(store.localCoverPath('动画'), isNull);
      expect(store.debugMapping, isEmpty);
    });

    test('prefs 里混了脏类型（数字 / 空串）→ 丢掉脏项、留下合法项', () async {
      SharedPreferences.setMockInitialValues({
        CollectionCoverStore.storageKey: jsonEncode({
          '动画': 'a.jpg',
          '音乐': 123,
          '日程': '',
        }),
      });
      final store = await _freshStore();
      expect(store.debugMapping, {'动画': 'a.jpg'});
    });

    test('根目录拿不到（原生插件缺失）→ 读返回 null、写不抛也不落盘', () async {
      final store = CollectionCoverStore.instance;
      store.resetForTest(); // rootDirOverride = null（测试环境无 path_provider）
      await store.ensureLoaded();

      expect(store.localCoverPath('动画'), isNull);
      expect(await store.saveLocalCover('动画', _png), isNull);
    });
  });
}
