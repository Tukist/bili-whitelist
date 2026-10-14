/// 「界面偏好」本地存储（v2.36.0 起）：底部提示条开关 [showTips]
/// （用户原话：「可以在设置里关掉底部的黑框提示」）+ v2.40.0 的**写操作总开关**
/// [writeActionsEnabled] 与**上次选的收藏夹** [favFolderId]
/// + v2.51.0 的「**免流兼容（实验）**」总开关 [streamCompatEnabled]
/// + v2.53.0 的**上次选的清晰度** [preferredQuality]。
///
/// 为什么单独开一个 store，而不是塞进 [UiCopyStore] 或 [DanmakuSettingsStore]：
/// - [UiCopyStore] 存的是「一句话被改成了什么」的**文案覆盖表**（key = 文案 id，
///   值 = 用户改的字符串），语义是"改写内容"；
/// - [DanmakuSettingsStore] 的值对象是**弹幕设置**（字号/速度/透明度…）；
/// - 这里是"界面**行为**开关"，值与上面两者都不同类 —— 混进去会让那两个
///   store 的 `resetForTest` / 序列化语义变得含糊（见 `inbox_card_style_store.dart`
///   的同类理由：单值 store 只存一个语义）。
///
/// 读写风格沿用 [ThemeStore] / [InboxCardStyleStore] / [ClipboardLinkStore]：
/// `ensureLoaded` 幂等、读/写失败一律静默降级（读失败 = 默认值，写失败 = 本次
/// 内存生效、下次启动回到上次成功保存的值），key 一律 `ui:` 前缀，
/// 不崩、不影响启动。
///
/// ★ [showTips] **默认开**：关提示是"我想清静"的主动诉求，不该是默认预期；
/// 默认关会让用户觉得 App 坏了（点什么都没反馈）。
///
/// ★ [writeActionsEnabled] **默认关**（v2.40.0+）：见该字段的注释。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 默认清晰度档位（1080P）——与取流接口的默认 `qn=80` 同值
/// （`playview_api.dart` 的 `kPlayViewQn`，两处都写 80 是因为它们分别是
/// 「请求默认值」与「用户偏好默认值」，语义不同但必须同值）。
///
/// ⚠️ 默认值**不能改小**：用户没选过清晰度时行为必须与 v2.52.0 逐字节一致
/// （取流一直发的就是 `qn=80`）。
const int kPreferredQualityDefault = 80;

/// 「界面偏好」存储（单例）。
class UiPrefsStore extends ChangeNotifier {
  /// 底部提示条开关的存储 key（bool；缺省/读失败 = true，默认开）。
  static const String showTipsKey = 'ui:show_tips';

  /// 写操作总开关的存储 key（bool；缺省/读失败 = false，**默认关**）。
  static const String writeActionsKey = 'ui:write_actions';

  /// 「免流兼容（实验）」开关的存储 key（bool；缺省/读失败 = false，**默认关**）。
  static const String streamCompatKey = 'ui:stream_compat';

  /// 上次选的收藏夹 id 的存储 key（int；缺省/读失败 = null，没有"上次"）。
  static const String favFolderKey = 'ui:fav_folder_id';

  /// 上次选的清晰度档位（`qn`）的存储 key（int；缺省/读失败 = 1080P）。
  static const String qualityKey = 'ui:preferred_quality';

  /// 全局单例（启动流程读、设置页写、`AppSnack` 每次弹提示前读）。
  static final UiPrefsStore instance = UiPrefsStore._();

  UiPrefsStore._();

  bool _showTips = true;
  bool _writeActionsEnabled = false;
  bool _streamCompatEnabled = false;
  bool _streamCompatSessionFallback = false;
  int? _favFolderId;

  /// 上次选的清晰度档位（v2.53.0+，默认 [kPreferredQualityDefault] = 1080P）。
  int _preferredQuality = kPreferredQualityDefault;
  bool _loaded = false;

  /// 是否允许弹「提示 / 成功 / 门禁」类底部提示条（默认 true）。
  ///
  /// ⚠️ **只管 info 类**：错误（[SnackKind.error]）与带撤销按钮的提示
  /// 一律不受它影响，判定集中在 `AppSnack.allows` 一处（关掉提示不该让失败
  /// 静默，也不该把"撤销"这个挽回入口一起关掉）。
  bool get showTips => _showTips;

  /// **写操作总开关**（v2.40.0+，默认 **false**）：点赞 / 投币 / 收藏三个
  /// 按钮是否出现。
  ///
  /// 为什么一个"能用的功能"要默认关：
  /// - 这三个动作**改的是用户真实的 B 站账号**（点赞进动态、收藏进收藏夹、
  ///   投币扣真硬币），而且**这个 App 在此之前的全部历史行为都是只读**——
  ///   用户装它就是为了"安静地看白名单视频"，默认多出一排能改账号状态的按钮
  ///   与该预期相悖；
  /// - 误触的代价不对称：多按一下「点赞」会通知到关注我的人，多按一下
  ///   「投币」直接扣硬币且 B 站**不支持撤回**。默认关 = 让"想写"的人自己
  ///   开一次闸，比让所有人默认承担误触风险合理；
  /// - 开关本身就是一道**知情确认**：开启前设置页那段说明写清了三个动作各
  ///   自不可逆在哪（见 manage_panel 的「写操作」分区）。
  bool get writeActionsEnabled => _writeActionsEnabled;

  /// **「免流兼容（实验）」开关**（v2.51.0+，默认 **false**）：视频/音频**流类**
  /// 请求的 User-Agent 是否换成 `kBiliAppUA`（对齐 B 站官方 Android App 特征，
  /// 期望落进运营商定向免流范围）。
  ///
  /// 为什么默认关、且标「实验」：
  /// - **可能让播放变糟**：仓库实测过反向的事实——非浏览器 UA 请求
  ///   `.bilivideo.com` 流会 403（见 `config.dart` 的 `kBrowserUA` 注释）。
  ///   也就是说这个开关在"本来能播"的设备上有把播放搞挂的真实风险；
  /// - **收益不确定**：流本来就发往 B 站官方 CDN，运营商若按域名放行则现在
  ///   已经在免流；只有"按 App 特征判定"时才可能因此改变，本机无从验证；
  /// - 所以：默认关 + 文案写明「实验 / 取不到流会自动切回普通模式」，把决定权
  ///   与止损办法一起交给用户（同 [writeActionsEnabled] 的"默认关 + 知情确认"思路）。
  ///
  /// 三条豁免仍然成立：**API 头表、图片请求、弹幕 WS 握手、登录页 WebView
  /// 一律不受本开关影响**（判定集中在 `config.dart` 的 `streamUserAgent()`）。
  bool get streamCompatEnabled => _streamCompatEnabled;

  /// 「免流兼容（实验）」是否已在**本次运行会话**内被自动回退
  /// （v2.51.1+，**纯内存、永不落盘**）。
  ///
  /// 由来：开关打开后官方 App 特征 UA 可能直接被 CDN 403（仓库实测过这个方向），
  /// 播放页观察到「流确实起不来」时会**自动回退**到浏览器 UA 并续播
  /// （见 `player_page.dart` 的 `_autoFallbackStreamCompat`）。回退只影响
  /// [streamUserAgent] 的取值（[streamCompatInUse]），**不动
  /// [streamCompatEnabled] 的值、也不动盘上的记录**：
  /// - 这个开关的收益在**运营商网络**上才成立（例如蜂窝数据免流、Wi-Fi 不免），
  ///   一次失败就永久关掉它，"换个网络本来能用"的用户自己都找不回来；
  /// - 会话内回退 + 播放页明说一句，代价最小；想彻底关掉，设置页那个开关随时在。
  ///
  /// 生命周期：进程内存（重启 App 即清）；用户在设置页**重新打开**开关
  /// （[setStreamCompatEnabled] 传 true）也会清 —— 那是"我要再试一次"的明确意图。
  bool get streamCompatSessionFallback => _streamCompatSessionFallback;

  /// 标记「本次会话内官方 App UA 取不到流，已自动回退浏览器 UA」。
  /// 幂等；**不落盘、不改** [streamCompatEnabled]（见字段注释）。
  ///
  /// v2.53.0 起**会发 `notifyListeners`**：个人页「取流状态」要把这一次回退
  /// 显示成「App 形态已在本会话回退」—— 回退是静默发生的（不改用户设置），
  /// 不重建界面的话用户会一直以为还在走 App 形态（正是要避免的那种误解）。
  /// 代价只是一次重建，且回退发生在播放失败现场（异步、不在 build 中）。
  void markStreamCompatSessionFallback() {
    if (_streamCompatSessionFallback) return;
    _streamCompatSessionFallback = true;
    notifyListeners();
  }

  /// 上次收藏到的收藏夹 id（null = 还没有"上次"）。
  ///
  /// 存在本地 prefs 而**不写进 Gist 配置**：Gist 里放的是白名单/合集这类
  /// 跨设备同步的内容；"我上次把视频收进哪个夹"是本机操作习惯，跨设备同步
  /// 反而可能指到一个别的账号的夹 id 上。
  int? get favFolderId => _favFolderId;

  /// 上次选的清晰度档位（`qn`，v2.53.0+，缺省 [kPreferredQualityDefault] = 1080P）。
  ///
  /// 存在本地 prefs 而**不写进 Gist 配置**（同 [favFolderId]）：清晰度能拿到
  /// 哪一档取决于**这台设备/这条网络**的登录态与取流形态（PlayView 匿名只有
  /// 480P），跨设备同步过去只会同步一个拿不到的档位。
  int get preferredQuality => _preferredQuality;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘，之后直接返回）。
  ///
  /// 读失败 → 回默认（提示开 / 写操作关 / 免流兼容关 / 无上次收藏夹 /
  /// 清晰度 1080P），不抛。五个值里只要有一个与当前不同就发通知。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    var showTips = true;
    var writeActions = false;
    var streamCompat = false;
    int? favFolder;
    var quality = kPreferredQualityDefault;
    try {
      final prefs = await SharedPreferences.getInstance();
      showTips = prefs.getBool(showTipsKey) ?? true;
      writeActions = prefs.getBool(writeActionsKey) ?? false;
      streamCompat = prefs.getBool(streamCompatKey) ?? false;
      final fav = prefs.getInt(favFolderKey);
      favFolder = (fav != null && fav > 0) ? fav : null;
      final q = prefs.getInt(qualityKey);
      quality = (q != null && q > 0) ? q : kPreferredQualityDefault;
    } catch (_) {
      // 存储异常：按默认值启动（提示开 / 写操作关 / 免流兼容关 / 无上次收藏夹 /
      // 清晰度 1080P）
      showTips = true;
      writeActions = false;
      streamCompat = false;
      favFolder = null;
      quality = kPreferredQualityDefault;
    }
    _loaded = true;
    if (showTips == _showTips &&
        writeActions == _writeActionsEnabled &&
        streamCompat == _streamCompatEnabled &&
        favFolder == _favFolderId &&
        quality == _preferredQuality) {
      return;
    }
    _showTips = showTips;
    _writeActionsEnabled = writeActions;
    _streamCompatEnabled = streamCompat;
    _favFolderId = favFolder;
    _preferredQuality = quality;
    notifyListeners();
  }

  /// 开关：立即生效（`notifyListeners` → 设置页开关跟着走）并持久化。
  /// 写失败静默（本次已生效，下次启动回到上次成功保存的值）。
  Future<void> setShowTips(bool value) async {
    if (_showTips != value) {
      _showTips = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showTipsKey, value);
    } catch (_) {
      // 写入失败静默（本次已生效，下次启动回到上次成功保存的值）
    }
  }

  /// 写操作总开关：语义与 [setShowTips] 完全一致（立即生效 + 静默持久化）。
  Future<void> setWriteActionsEnabled(bool value) async {
    if (_writeActionsEnabled != value) {
      _writeActionsEnabled = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(writeActionsKey, value);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 「免流兼容（实验）」开关：语义与 [setShowTips] 完全一致
  /// （立即生效 + 静默持久化）。
  ///
  /// 打开时顺带清掉 [streamCompatSessionFallback]：一次自动回退之后用户又手动
  /// 打开它，语义就是「再试一次」（可能换到了能免流的网络），不该被上一次的
  /// 回退一直压着。
  Future<void> setStreamCompatEnabled(bool value) async {
    if (value) _streamCompatSessionFallback = false;
    if (_streamCompatEnabled != value) {
      _streamCompatEnabled = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(streamCompatKey, value);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 记住"上次收进了哪个夹"（写失败静默，下次仍按没有"上次"处理）。
  Future<void> setFavFolderId(int? value) async {
    final next = (value != null && value > 0) ? value : null;
    if (_favFolderId != next) {
      _favFolderId = next;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next == null) {
        await prefs.remove(favFolderKey);
      } else {
        await prefs.setInt(favFolderKey, next);
      }
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 记住"上次选的清晰度"（v2.53.0+；写失败静默，本次已生效、下次回到上次
  /// 成功保存的值）。非正数（0/负）按"没选过"处理 → 回到默认 1080P —— 播放页
  /// 拿它当请求的 `qn`，传 0 出去等于让服务端自己挑，与用户的"我选过"无关。
  Future<void> setPreferredQuality(int value) async {
    final next = value > 0 ? value : kPreferredQualityDefault;
    if (_preferredQuality != next) {
      _preferredQuality = next;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(qualityKey, next);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({
    bool? showTips,
    bool writeActionsEnabled = false,
    bool streamCompatEnabled = false,
    bool streamCompatSessionFallback = false,
    int? favFolderId,
    int preferredQuality = kPreferredQualityDefault,
    bool loaded = false,
  }) {
    _showTips = showTips ?? true;
    _writeActionsEnabled = writeActionsEnabled;
    _streamCompatEnabled = streamCompatEnabled;
    _streamCompatSessionFallback = streamCompatSessionFallback;
    _favFolderId = favFolderId;
    _preferredQuality = preferredQuality;
    _loaded = loaded;
  }
}
