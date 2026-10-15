/// 掌厅抓取的**会话与读数存储**（v2.54.0）。
///
/// 存什么、不存什么（用户要求：不保存验证码/服务密码，日志不打印手机号全号）：
/// - **手机号全号 → 只进 flutter_secure_storage**（key [phoneStorageKey]），而且
///   读出来之后**立刻降成尾号**（[phoneTail]），内存模型里只有"****1234"；
/// - **短信验证码 / 服务密码：不存、不碰**（这条路线不需要服务密码；验证码只
///   在掌厅页面里由用户手动输入，App 读不到也不去读）；
/// - SharedPreferences 里只放**非敏感**状态：登录态、尾号、上次读数、上次错误、
///   失败次数。日志里也只打尾号（见 [phoneTail] 的用法）。
///
/// 另外：`needsRelogin` 一旦为真，轮询策略（`cmcc_poll_policy.dart`）会**停止
/// 自动查询**——登录失效要用户自己收短信重新登录，App 绝不代发验证码。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cmcc_plan.dart';
import 'cmcc_poll_policy.dart';
import 'secure_store.dart';

/// 掌厅登录态（界面直接显示）。
enum CmccLoginState {
  /// 还没查过（首次进入 App）。
  unknown,

  /// 没登录过 / 已被用户清掉本机记录。
  loggedOut,

  /// 有会话（Cookie 在 WebView 里，本 App 只是记着"上次读到过数据"）。
  loggedIn,

  /// 会话失效（页面回到登录页 / 接口说未登录）→ 停轮询，等用户重登。
  needRelogin,
}

/// 登录态 → 界面文案（**必须如实**：不知道就说没登录，失效就说要重登）。
String cmccLoginStateLabel(CmccLoginState state) {
  switch (state) {
    case CmccLoginState.unknown:
    case CmccLoginState.loggedOut:
      return kCmccStateLoggedOut;
    case CmccLoginState.loggedIn:
      return kCmccStateLoggedIn;
    case CmccLoginState.needRelogin:
      return kCmccStateNeedRelogin;
  }
}

/// 一次**自动读到**的读数（持久化用；界面据此显示"上次自动更新"）。
class CmccAutoReading {
  /// 通用流量已用（GB）——**喂差值算法的就是这一个数**。
  final double generalUsedGb;

  /// 定向流量已用（GB）；null = 掌厅没给读数（**不是 0**）。
  final double? directionalUsedGb;

  /// 其他 / 区域流量已用（GB）；null = 没给读数。
  final double? otherUsedGb;

  /// 总流量已用（GB）；null = 没给读数。
  final double? totalUsedGb;

  /// 读数来自 C（接口）还是 B（页面文字）。
  final CmccReadingSource source;

  /// 读到的时刻。
  final DateTime at;

  const CmccAutoReading({
    required this.generalUsedGb,
    this.directionalUsedGb,
    this.otherUsedGb,
    this.totalUsedGb,
    required this.source,
    required this.at,
  });

  /// 从解析结果造一条（[CmccReading] → 存储形态）。
  factory CmccAutoReading.fromReading(CmccReading r, DateTime at) =>
      CmccAutoReading(
        generalUsedGb: r.general.usedGb!,
        directionalUsedGb: r.directional?.usedGb,
        otherUsedGb: r.other?.usedGb,
        totalUsedGb: r.total?.usedGb,
        source: r.source,
        at: at,
      );

  /// 定向流量有没有读数（界面据此显示"掌厅没给定向流量读数"）。
  bool get hasDirectional => directionalUsedGb != null;

  Map<String, Object?> toJson() => {
        'general': generalUsedGb,
        if (directionalUsedGb != null) 'directional': directionalUsedGb,
        if (otherUsedGb != null) 'other': otherUsedGb,
        if (totalUsedGb != null) 'total': totalUsedGb,
        'src': source == CmccReadingSource.pageText ? 'text' : 'api',
        'at': at.millisecondsSinceEpoch,
      };

  /// 反序列化；结构不对（缺 general/at）→ null（当作"没有读数"）。
  static CmccAutoReading? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final g = raw['general'];
    final at = raw['at'];
    if (g is! num || at is! num) return null;
    double? opt(Object? v) => v is num ? v.toDouble() : null;
    return CmccAutoReading(
      generalUsedGb: g.toDouble(),
      directionalUsedGb: opt(raw['directional']),
      otherUsedGb: opt(raw['other']),
      totalUsedGb: opt(raw['total']),
      source: raw['src'] == 'text'
          ? CmccReadingSource.pageText
          : CmccReadingSource.api,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
    );
  }

  @override
  String toString() => 'CmccAutoReading(${generalUsedGb}GB, '
      'dir=$directionalUsedGb, src=${source.name}, at=$at)';
}

/// 掌厅会话存储（单例 + ChangeNotifier；界面与抓取页共用一份状态）。
class CmccSessionStore extends ChangeNotifier {
  /// SharedPreferences 的 key（**只放非敏感状态**）。
  static const String prefsKey = 'cmcc:session';

  /// 手机号全号在 secure storage 里的 key。
  static const String phoneStorageKey = 'cmcc_phone';

  /// 全局单例。
  static final CmccSessionStore instance = CmccSessionStore._();

  CmccSessionStore._();

  CmccLoginState _loginState = CmccLoginState.unknown;
  String? _phoneTail;
  CmccAutoReading? _reading;
  String? _lastError;
  DateTime? _lastAttemptAt;
  int _failures = 0;
  bool _needsRelogin = false;
  bool _loaded = false;

  CmccLoginState get loginState => _loginState;

  /// 手机号尾号（形如 `****1234`）；null = 还不知道 / 没存过。
  String? get phoneTail => _phoneTail;

  /// 上次**自动读到**的读数（null = 一直没读成）。
  CmccAutoReading? get reading => _reading;

  /// 上次失败的原因（可读中文；成功时清空）。
  String? get lastError => _lastError;

  /// 上次尝试的时刻（成功或失败都算）。
  DateTime? get lastAttemptAt => _lastAttemptAt;

  /// 连续失败次数（退避用；成功清零）。
  int get failures => _failures;

  /// 需要重新登录（真 → 停止自动轮询）。
  bool get needsRelogin => _needsRelogin;

  /// 有没有拿到过自动读数（界面决定显示数字还是"还没读到过"）。
  bool get hasReading => _reading != null;

  /// 当前轮询计划（界面显示"多久查一次 / 为什么停"）。
  CmccPollPlan get pollPlan => cmccNextPollPlan(
        consecutiveFailures: _failures,
        needsRelogin: _needsRelogin,
      );

  /// 启动时读一次（幂等）。
  ///
  /// 读 secure storage 只为了拿尾号：**拿到全号立刻降成尾号**，不留在字段里。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) _applyJson(raw);
    } catch (_) {
      // 坏数据当作"没存过"
    }
    try {
      final storage = createSecureStorage();
      final phone = await storage.read(key: phoneStorageKey);
      final tail = cmccPhoneTail(phone);
      if (tail != null) _phoneTail = tail;
    } catch (_) {
      // 通道不可用 / 读失败：尾号未知，不影响其它状态
    }
    _loaded = true;
    notifyListeners();
  }

  /// 记下手机号（**全号进 secure storage，内存里只留尾号**）。
  ///
  /// ⚠️ 这里**不**改登录态：手机上 `#phone` 的取值在**登录前**就存在（那是用户
  /// 自己填进去的），拿它当"已登录"的证据会把登录流程判成"会话失效"。登录态只由
  /// [recordSuccess]（真读到数据）与 [markNeedRelogin]（页面回到登录页）改。
  Future<void> savePhone(String phone) async {
    final tail = cmccPhoneTail(phone);
    if (tail == null) return;
    _phoneTail = tail;
    notifyListeners();
    try {
      final storage = createSecureStorage();
      await storage.write(key: phoneStorageKey, value: phone);
    } catch (_) {
      // 写失败：本次会话仍然能用（尾号在内存里），下次启动尾号未知
    }
    await _save();
  }

  /// 清掉本机记的手机号（**不退出掌厅登录**：WebView 里的 Cookie 不动）。
  Future<void> forgetPhone() async {
    _phoneTail = null;
    _loginState = CmccLoginState.loggedOut;
    notifyListeners();
    try {
      final storage = createSecureStorage();
      await storage.delete(key: phoneStorageKey);
    } catch (_) {}
    await _save();
  }

  /// 读到数据 → 记成功（清失败计数与错误）。
  Future<void> recordSuccess(CmccReading reading, DateTime at) async {
    _reading = CmccAutoReading.fromReading(reading, at);
    _lastAttemptAt = at;
    _lastError = null;
    _failures = cmccResetFailures();
    _needsRelogin = false;
    _loginState = CmccLoginState.loggedIn;
    notifyListeners();
    await _save();
  }

  /// 读失败 → 记一句可读原因（累加失败计数，供退避用）。
  Future<void> recordFailure(String reason, DateTime at) async {
    _lastAttemptAt = at;
    _lastError = reason;
    _failures = cmccBumpFailures(_failures);
    notifyListeners();
    await _save();
  }

  /// 会话失效（页面回到登录页 / 接口说未登录）→ **停止轮询**，等用户重登。
  Future<void> markNeedRelogin([String reason = kCmccStateNeedRelogin]) async {
    _needsRelogin = true;
    _loginState = CmccLoginState.needRelogin;
    _lastError = reason;
    _lastAttemptAt = DateTime.now();
    notifyListeners();
    await _save();
  }

  /// 恢复成"已登录"（用户重登成功时调）。
  Future<void> markLoggedIn() async {
    _needsRelogin = false;
    _failures = cmccResetFailures();
    _lastError = null;
    if (_loginState != CmccLoginState.loggedIn) {
      _loginState = CmccLoginState.loggedIn;
      notifyListeners();
      await _save();
    }
  }

  /// 测试用：重置内存态（不触碰存储）。
  @visibleForTesting
  void resetForTest({
    CmccLoginState loginState = CmccLoginState.unknown,
    String? phoneTail,
    CmccAutoReading? reading,
    String? lastError,
    DateTime? lastAttemptAt,
    int failures = 0,
    bool needsRelogin = false,
    bool loaded = false,
  }) {
    _loginState = loginState;
    _phoneTail = phoneTail;
    _reading = reading;
    _lastError = lastError;
    _lastAttemptAt = lastAttemptAt;
    _failures = failures;
    _needsRelogin = needsRelogin;
    _loaded = loaded;
  }

  /// 序列化（纯函数，测试直接钉）。
  String encode() => jsonEncode({
        'state': _loginState.name,
        'tail': _phoneTail,
        'error': _lastError,
        'attemptAt': _lastAttemptAt?.millisecondsSinceEpoch,
        'failures': _failures,
        'needRelogin': _needsRelogin,
        'reading': _reading?.toJson(),
      });

  /// 反序列化（纯函数）；坏数据一律忽略、退回默认值。
  void _applyJson(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final state = decoded['state'];
    if (state is String) {
      for (final v in CmccLoginState.values) {
        if (v.name == state) _loginState = v;
      }
    }
    final tail = decoded['tail'];
    if (tail is String && tail.isNotEmpty) _phoneTail = tail;
    final error = decoded['error'];
    if (error is String && error.isNotEmpty) _lastError = error;
    final at = decoded['attemptAt'];
    if (at is num) {
      _lastAttemptAt = DateTime.fromMillisecondsSinceEpoch(at.toInt());
    }
    final failures = decoded['failures'];
    if (failures is num) _failures = failures.toInt();
    _needsRelogin = decoded['needRelogin'] == true;
    _reading = CmccAutoReading.fromJson(decoded['reading']);
    if (_needsRelogin) _loginState = CmccLoginState.needRelogin;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encode());
    } catch (_) {
      // 写失败静默：本次已生效，下次启动回到上次成功保存的值
    }
  }
}
