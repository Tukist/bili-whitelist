/// 加载文案池（P0 块化与动效系统）。
///
/// 三个池对应三种场景，值都定义在 [UiCopyStore.kDefaultCopies]，
/// 用户可在设置页改写（key 就是池里存的那个 id）：
/// - [kLoadingPoolPage]：整页加载（首屏 / 冷启动）
/// - [kLoadingPoolFooter]：列表尾部"正在取下一页"
/// - [kLoadingPoolEmpty]：空态兜底的一句话（不是"没有数据"的说明，
///   是等人时的一句闲话）
///
/// 挑词是**确定性**的：同一个 seed 永远同一条。理由和半调网点一样——
/// 每次 build 换一句会让界面闪变，也没法写测试。seed 由调用方给
/// （一般是页面名 + 列表标识），所以"同一个页面每次进来是同一句"。
library;

import '../widgets/dot_halftone.dart'; // 复用 stableSeed（FNV-1a 确定性哈希）
import 'ui_copy_store.dart';

/// 整页加载池（8 条）
const List<String> kLoadingPoolPage = <String>[
  'loading.line.1',
  'loading.line.2',
  'loading.line.3',
  'loading.line.4',
  'loading.line.5',
  'loading.line.6',
  'loading.line.7',
  'loading.line.8',
];

/// 列表尾部 / 分页加载池（4 条）
const List<String> kLoadingPoolFooter = <String>[
  'footer.loading.1',
  'footer.loading.2',
  'footer.loading.3',
  'footer.loading.4',
];

/// 空态兜底池（3 条）
const List<String> kLoadingPoolEmpty = <String>[
  'loading.empty.1',
  'loading.empty.2',
  'loading.empty.3',
];

/// 从池里挑一条：**确定性**（同 seed 同一条，不闪变、可测试）+ 用户覆盖优先。
///
/// [pool] 为空返回空串（调用方据此退回无文案形态）；池里的 id 认不出来时
/// [UiCopyStore.text] 会**原样返回 id**，漏配的 id 会在界面上显形而不是静默留白。
String loadingCopyFor({required List<String> pool, required String seed}) {
  if (pool.isEmpty) return '';
  return UiCopyStore.instance.text(pool[stableSeed(seed) % pool.length]);
}
