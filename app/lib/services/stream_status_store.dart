/// 「最近一次取流」的实测事实存储（v2.53.0，个人页「取流状态」用）。
///
/// ## 为什么单独开一个 store
///
/// 用户要的是「一眼看出现在走的是哪条路」。「走哪条路」有两半：
/// - **当前形态**（普通模式 / App 形态 / App 形态已在本会话回退）：这是**开关 +
///   会话回退标记**的组合，判据已经在 [UiPrefsStore] 与 `config.streamCompatInUse()`
///   里，不在这里存第二份（存了必然不同步）；
/// - **最近一次取流的实测事实**（接口来源、清晰度档位、带没带登录 Cookie）：
///   只有取流那一刻才知道，运行期到处可能变、重启就没了 —— 这一半是本 store
///   的职责，**落盘**（重启后仍能看到上次结果）。
///
/// 为什么不塞进 [UiPrefsStore]：那里存的是"界面**行为**开关"（提示条、写操作、
/// 免流兼容、上次收藏夹），语义是"用户设的值"；这里是"运行时发生的事实"
/// （用户没设过任何东西），混进去会让那个 store 的序列化语义变含糊
/// （同 `inbox_card_style_store.dart` 里"单值 store 只存一个语义"的理由）。
///
/// ## 写盘策略
///
/// 每次取流成功写一次（4 个小 key），**不做 diff**：一次播放只有一次取流，
/// 写盘量可以忽略；而 `at` 每次都在变，diff 也省不掉写。读/写失败一律静默
/// （读失败 = 当作"还没有记录"，写失败 = 本次内存生效、下次启动回到上次成功
/// 保存的值），key 一律 `stream:` 前缀 —— 与 [UiPrefsStore] 同一套风格。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 取流走的是哪条接口（v2.53.0）。
///
/// 两种形态的差别不只是 UA：网页接口（`x/player/wbi/playurl`）下发的是
/// **`platform=pc` 直链**，取流要「浏览器 UA + Referer」；官方 App 形态走
/// gRPC `PlayView`（见 `api/playview_api.dart`），下发 **`platform=android`
/// 直链**，取流要「App 特征 UA + 不带 Referer」。**免流是否生效本机无从判定**
/// （那是运营商计费侧的事），这里只记"我们发出去的是哪一种"。
enum StreamSource {
  /// 网页接口（默认路径，最稳）。
  web,

  /// 官方 App gRPC `PlayView`（「免流兼容（实验）」开关打开且本会话未回退）。
  app;

  /// 存储用的稳定字符串（枚举名变了也不该让旧记录读不出来，所以显式定型）。
  String get storageValue => switch (this) {
        StreamSource.web => 'web',
        StreamSource.app => 'app',
      };

  /// 从存储字符串还原；不认识的值返回 null（按"没有记录"处理，不崩）。
  static StreamSource? fromStorage(String? raw) => switch (raw) {
        'web' => StreamSource.web,
        'app' => StreamSource.app,
        _ => null,
      };
}

/// 「最近一次取流」存储（单例）。
class StreamStatusStore extends ChangeNotifier {
  /// 接口来源的存储 key（String：`web` / `app`）。
  static const String sourceKey = 'stream:last_source';

  /// 清晰度档位的存储 key（int；B 站约定 16=360P 32=480P 64=720P 80=1080P）。
  static const String qualityKey = 'stream:last_quality';

  /// 是否带了登录 Cookie 的存储 key（bool）。
  static const String cookieKey = 'stream:last_cookie';

  /// 取流时刻的存储 key（int：`millisecondsSinceEpoch`）。
  static const String atKey = 'stream:last_at';

  /// 全局单例（播放页取流成功时写、个人页读）。
  static final StreamStatusStore instance = StreamStatusStore._();

  StreamStatusStore._();

  StreamSource? _source;
  int _quality = 0;
  bool _hadLoginCookie = false;
  DateTime? _at;
  bool _loaded = false;

  /// 最近一次取流走的接口（null = 本次安装还没有成功取过流）。
  StreamSource? get source => _source;

  /// 最近一次取流拿到的清晰度档位（0 = 解析不出，别当 360P）。
  int get quality => _quality;

  /// 最近一次取流**是否带了登录 Cookie**。
  ///
  /// 两条路径的判据其实是同一件事：本机有没有**未过期**的 `SESSDATA`
  /// （网页接口靠 dio 拦截器注入，PlayView 靠 `playViewLoginCookie()` 显式塞进
  /// 请求头）。所以播放页统一用 `_hasValidSession()` 的结果记这一个布尔。
  bool get hadLoginCookie => _hadLoginCookie;

  /// 最近一次取流的时刻（本地时间；null = 没有记录）。
  DateTime? get at => _at;

  /// 有没有一条可显示的记录（来源与时刻都在才算）。
  bool get hasRecord => _source != null && _at != null;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘）。
  ///
  /// 读失败 → 全部回"没有记录"，不抛。四项里只要有一项与当前不同就发通知。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    StreamSource? nextSource;
    var nextQuality = 0;
    var nextCookie = false;
    DateTime? nextAt;
    try {
      final prefs = await SharedPreferences.getInstance();
      nextSource = StreamSource.fromStorage(prefs.getString(sourceKey));
      nextQuality = prefs.getInt(qualityKey) ?? 0;
      nextCookie = prefs.getBool(cookieKey) ?? false;
      final ms = prefs.getInt(atKey);
      nextAt = (ms != null && ms > 0)
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : null;
    } catch (_) {
      // 存储异常：按"没有记录"启动（个人页那行说明不显示实测信息）
      nextSource = null;
      nextQuality = 0;
      nextCookie = false;
      nextAt = null;
    }
    _loaded = true;
    if (nextSource == _source &&
        nextQuality == _quality &&
        nextCookie == _hadLoginCookie &&
        nextAt == _at) {
      return;
    }
    _source = nextSource;
    _quality = nextQuality;
    _hadLoginCookie = nextCookie;
    _at = nextAt;
    notifyListeners();
  }

  /// 记下"刚刚用 [source] 取到了清晰度 [quality]、[hadLoginCookie] 决定带没带
  /// 登录凭据"。**取流成功那一刻调用**（播放页 `_loadStreamAndPlay`）。
  ///
  /// 立即生效（`notifyListeners` → 个人页那行说明跟着走）并持久化；
  /// 写失败静默（本次已生效，下次启动回到上次成功保存的值）。
  Future<void> record({
    required StreamSource source,
    required int quality,
    required bool hadLoginCookie,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    _source = source;
    _quality = quality;
    _hadLoginCookie = hadLoginCookie;
    _at = when;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(sourceKey, source.storageValue);
      await prefs.setInt(qualityKey, quality);
      await prefs.setBool(cookieKey, hadLoginCookie);
      await prefs.setInt(atKey, when.millisecondsSinceEpoch);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({
    StreamSource? source,
    int quality = 0,
    bool hadLoginCookie = false,
    DateTime? at,
    bool loaded = false,
  }) {
    _source = source;
    _quality = quality;
    _hadLoginCookie = hadLoginCookie;
    _at = at;
    _loaded = loaded;
  }
}
