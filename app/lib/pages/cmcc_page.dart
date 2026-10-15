/// 中国移动掌厅抓取页（v2.54.0，路线 C → B → D 的落地处）。
///
/// ## 页面在做什么（三步降级，每条失败都给可读原因）
///
/// 1. **C（首选）**：WebView 打开掌厅页面 → 注入脚本钩住 `fetch`/`XHR`
///    （`cmcc_hook_script.dart`）→ 命中的响应体回传 → Dart 解密 + 解析
///    （`cmcc_plan.dart`）。**不自己维护接口 URL**，页面自己会调；
/// 2. **B（降级）**：C 三次没钩到（或钩到但解不出）→ 读 `document.body.innerText`
///    用正则抠「通用/定向/其他/总」的已用（[parsePageText]）；
/// 3. **D（兜底）**：B 也没认出数字 → **不做解析**，页面原样留在下面让用户自己
///    看，并给一句人话 + 提示"仍可用手动录入"。
///
/// 每次尝试的节奏（用户给的现场事实：页面打开后要等 8 秒才自己发接口）：
/// 第 1 次 = 注入 + 点「点击刷新」+ 等 8 秒；第 2/3 次 = 先 reload 再走一遍。
///
/// ## ⚠️ 两条必须写明的限制
///
/// 1. **注入时机**：现有依赖 `webview_flutter` 没有 document-start 注入（见
///    `cmcc_hook_script.dart` 文件头）。所以脚本在 `onPageStarted` /
///    `onPageFinished` 各注入一次（注入在驱动里做），并在**注入之后点一下页面里的
///    「点击刷新」**——掌厅的数据本来就要用户点一下才出，这一下点击会让页面重发
///    请求，钩子此时必然已就位。即便如此，**真机上仍有抓不到的可能**，届时走 B/D；
/// 2. **轮询只能发生在"这个页面活着"的时候**：WebView 抓取必须有一个真实的
///    WebView 存在，后台拿不到它。所以"30 分钟一次"落成**页面存活期间的定时**
///    （[cmccNextPollPlan] 决定间隔与退避），页面关掉就停；下次进来按同一套计划
///    继续。**不常驻一个 0 尺寸 WebView**：那等于在用户看不见的地方一直联网、
///    一直吃内存，与"安全第一"冲突。
///
/// ## 🚫 绝不自动重发验证码
///
/// 本页面对页面**只做这四件事**：加载登录页 / 加载首页 / 点白名单文案（刷新类，
/// 且先过黑名单，见 [cmccMayClickText]）/ 读可见文字与 `#phone` 的**值**。
/// 不代填手机号、不代填验证码、不点登录按钮、不调任何发码接口——收不到验证码
/// 时用户自己点（限流了就等一会儿再点），App 一句话都不替他发。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;

import '../services/cmcc_aes.dart';
import '../services/cmcc_capture_driver.dart';
import '../services/cmcc_hook_script.dart';
import '../services/cmcc_plan.dart';
import '../services/cmcc_session_store.dart';
import '../services/traffic_snapshot_store.dart';
import '../services/traffic_stats_service.dart';

/// 每次抓取尝试的等待时长（用户现场事实：页面打开后约 8 秒自己发接口）。
const Duration kCmccAttemptWait = Duration(seconds: 8);

/// 单次进页面最多尝试几次（第 2/3 次先 reload）。
const int kCmccMaxAttempts = 3;

/// 停在登录页时的复查间隔（**只读文字**，不发请求、不碰验证码）。
const Duration kCmccLoginRecheck = Duration(seconds: 3);

/// 页面上给用户的最后一句（D 路线）。
const String kCmccFallbackHint = '页面就在下面，你可以自己看，或用「手动录入」。';

/// C 与 B 都没读成时的原因（与单条失败的措辞不同，便于分辨卡在哪一步）。
const String kCmccFailBoth = '接口没钩到，页面文字也没认出通用流量。';

/// 会话失效那句（提示用户自己收短信重登）。
const String kCmccReloginReason =
    '需要重新登录：请你自己收短信重新登录，App 不会代发验证码。';

/// 抓取页的 key（测试锚点）。
const Key kCmccPageStatusKey = Key('cmcc-page-status');
const Key kCmccPageReasonKey = Key('cmcc-page-reason');
const Key kCmccPageRetryKey = Key('cmcc-page-retry');
const Key kCmccPageGoHomeKey = Key('cmcc-page-go-home');

/// 抓取当前状态（界面标题行用）。
enum CmccPhase {
  /// 正在打开页面 / 正在尝试。
  running,

  /// 停在登录页（等用户手动登录）。
  needLogin,

  /// 运营商侧维护中。
  maintenance,

  /// 读到了。
  ok,

  /// 读不到（原因见页面上的那句话）。
  failed,
}

/// 掌厅抓取页。
class CmccCapturePage extends StatefulWidget {
  /// 驱动工厂（测试注入替身用；null = 用真 WebView 驱动）。
  ///
  /// 为什么是这个形状：页面把"通道消息"入口 [onHook] 交给驱动，替身也能拿到
  /// 同一个入口，于是"钩到响应 → 解密 → 解析 → 落库 + 记自动快照"这条链路
  /// 在测试里能整条跑。
  final CmccCaptureDriver Function(void Function(String raw) onHook)?
      driverFactory;

  /// 取"现在"（测试可注入固定时钟）。
  final DateTime Function()? now;

  const CmccCapturePage({super.key, this.driverFactory, this.now});

  @override
  State<CmccCapturePage> createState() => _CmccCapturePageState();
}

class _CmccCapturePageState extends State<CmccCapturePage>
    with WidgetsBindingObserver {
  late final CmccSessionStore _store = CmccSessionStore.instance;
  static const TrafficStatsService _traffic = TrafficStatsService();

  CmccCaptureDriver? _driver;
  CmccPhase _phase = CmccPhase.running;

  /// 给用户看的状态行 + 失败原因（分开：状态说"在干什么"，原因说"为什么没成"）。
  String _status = '正在打开掌厅页面…';
  String? _reason;

  CmccReading? _reading;

  /// 已经试了几次（1..[kCmccMaxAttempts]）。
  int _attempt = 0;

  /// 一次尝试是否正在等待窗口里（防止同一文档里多次事件叠出两次尝试）。
  bool _capturing = false;

  /// 本次文档有没有钩到过命中的响应（没有 → 到点就 reload 重试）。
  bool _capturedThisDoc = false;

  /// 已经出结果（成功 / 已降级到 B/D / 已判定要重登）→ 不再接新结果。
  bool _settled = false;

  /// 最近一次读到的页面文字（B 路线用）。
  String _lastText = '';

  /// 页面当前状态（登录页 / 维护 / 首页）。
  CmccPageKind _pageKind = CmccPageKind.unknown;

  /// 是否已到过首页（决定"停在登录页"的复查要不要继续）。
  bool _homeSeen = false;

  Timer? _waitTimer;
  Timer? _pollTimer;
  Timer? _loginTimer;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_store.ensureLoaded());
    unawaited(_boot());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waitTimer?.cancel();
    _pollTimer?.cancel();
    _loginTimer?.cancel();
    _driver?.dispose();
    super.dispose();
  }

  /// 回前台：如果上一轮已经超过计划间隔，就补一次（页面还活着才做）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 定时器在后台可能被系统推迟，回前台补一次；需要重登时这里什么都不做
    if (_store.needsRelogin) return;
    unawaited(_resumeIfDue(force: false));
  }

  Future<void> _boot() async {
    _driver = widget.driverFactory?.call(_onHook) ??
        CmccWebViewDriver(onHook: _onHook);
    _driver!.bind(CmccPageBindings(
      // 注入脚本在驱动内部完成（onPageStarted 与 onPageFinished 各一次），
      // 页面只在"加载完成"后决定下一步
      onPageFinished: () => unawaited(_onPageLoaded()),
      onLoadError: (reason) {
        if (!mounted) return;
        setState(() {
          _phase = CmccPhase.failed;
          _status = '页面加载失败';
          _reason = reason;
        });
      },
    ));
    try {
      await _driver!.start(kCmccLoginUrl);
    } catch (e) {
      // 排查用日志：**不带手机号**（也不带页面内容）
      debugPrint('[cmcc] WebView 起不来：${e.runtimeType} $e');
      if (!mounted) return;
      setState(() {
        _phase = CmccPhase.failed;
        _status = '打不开掌厅页面';
        _reason = '系统 WebView 起不来（${e.runtimeType}）。可退出重进，或用手动录入。';
      });
      await _store.recordFailure(_reason!, _now());
      return;
    }
    if (mounted) setState(() {});
  }

  /// 主框架加载完成：顺手记手机号（只读 `#phone` 的**值**）+ 要一次页面文字。
  Future<void> _onPageLoaded() async {
    debugPrint('[cmcc] 页面加载完成，开始注入后的取数准备');
    unawaited(_tryRememberPhone());
    // 注入脚本已就位 → 点一下「点击刷新」，逼页面重发余量请求（钩子这时能钩到）
    try {
      await _driver?.pokeRefresh();
    } catch (_) {}
    try {
      await _driver?.requestText();
    } catch (_) {}
  }

  /// 记手机号：**只读输入框的值**，绝不代填；拿不到就当没有（不挡流程）。
  Future<void> _tryRememberPhone() async {
    try {
      final phone = await _driver?.readPhoneField();
      if (phone == null) return;
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      if (digits.length != 11 || !digits.startsWith('1')) return;
      await _store.savePhone(digits); // 全号只进 secure storage
      // 日志只允许出现尾号（cmccPhoneTail 的产物就是 ****1234）
      debugPrint('[cmcc] 记下手机号尾号 ${cmccPhoneTail(digits)}');
    } catch (_) {}
  }

  /// 通道消息（钩到的响应 / 页面文字）。
  void _onHook(String raw) {
    final msg = parseHookMessage(raw);
    if (msg == null) return;
    if (msg.kind == CmccHookKind.text) {
      unawaited(_onPageText(msg.text ?? ''));
      return;
    }
    unawaited(_onResponse(msg));
  }

  /// C 路线：拿到一条命中的接口响应 → 解密 + 解析。
  Future<void> _onResponse(CmccHookMessage msg) async {
    final body = msg.body ?? '';
    if (body.trim().isEmpty) return;
    // 会话失效（接口说"未登录"）→ 停轮询、等用户重登，**绝不代发验证码**
    if (looksLikeSessionExpired(body)) {
      await _stopForRelogin();
      return;
    }
    if (!msg.isWantedApi) return; // 双保险（脚本侧已过滤）
    _capturedThisDoc = true;
    // 排查用日志：接口名 + 体积 + 判成密文没有（**不打 body 内容**）
    debugPrint('[cmcc] 钩到 ${msg.api}：${body.length} 字节，'
        'cipher=${looksLikeCipherHex(body)}');
    final result = parsePlanBody(body);
    if (result.isOk) {
      await _settle(result.reading!);
      return;
    }
    // 解不出/字段变了：记下原因，等其它接口的响应或下一次尝试
    debugPrint('[cmcc] 解析失败：${result.error}');
    if (mounted && !_settled) {
      setState(() => _reason = result.error);
    }
  }

  /// B 路线的输入：页面可见文字（也用来判断"现在是登录页 / 维护 / 首页"）。
  Future<void> _onPageText(String text) async {
    if (text.trim().isEmpty) return;
    _lastText = text;
    final kind = classifyCmccPage(text);
    _pageKind = kind;
    switch (kind) {
      case CmccPageKind.login:
        if (_settled) return;
        if (_store.loginState == CmccLoginState.loggedIn ||
            _store.reading != null) {
          // 之前读过数据、现在又回到登录页 → 会话失效了
          await _stopForRelogin();
          return;
        }
        // ⚠️ 这里**不能**因为"见过首页"就跳过：用户点了「我已登录，去读数字」
        // 但其实还没登进去时，页面还是登录页，这时候必须把登录引导摆出来
        // （否则他会对着一个没有任何提示的页面发呆）。
        _loginTimer ??= Timer.periodic(kCmccLoginRecheck, (_) {
          // 只读文字：不发请求、不点任何按钮、更不碰验证码
          unawaited(_driver?.requestText() ?? Future<void>.value());
        });
        if (mounted) {
          setState(() {
            _phase = CmccPhase.needLogin;
            _status = '等你在这个页面里登录';
            _reason = kCmccFailNeedLogin;
          });
        }
        return;
      case CmccPageKind.maintenance:
        if (_settled) return;
        _settled = true;
        _waitTimer?.cancel();
        if (mounted) {
          setState(() {
            _phase = CmccPhase.maintenance;
            _status = '运营商侧维护中';
            _reason = kCmccFailMaintenance;
          });
        }
        await _recordFailure(kCmccFailMaintenance);
        return;
      case CmccPageKind.home:
        _homeSeen = true;
        _loginTimer?.cancel();
        _loginTimer = null;
        if (_settled) {
          // 之前判过"要重登"，而页面现在到了首页 → 说明用户刚刚自己重登成功了：
          // 清掉重登标记，继续干活（不然会一直卡在"需要重新登录"上）
          if (_store.needsRelogin) {
            _settled = false;
            _store.markLoggedIn();
          } else {
            return;
          }
        }
        if (_capturing) return;
        await _beginCapture();
        return;
      case CmccPageKind.unknown:
        if (mounted && !_settled && _reason == null) {
          setState(() => _reason = kCmccFailUnknownPage);
        }
        return;
    }
  }

  /// 开始一轮抓取（最多 [kCmccMaxAttempts] 次，第 2/3 次先 reload）。
  Future<void> _beginCapture() async {
    if (_settled || !mounted) return;
    if (_attempt >= kCmccMaxAttempts) {
      await _fallbackToText();
      return;
    }
    _attempt++;
    _capturing = true;
    _capturedThisDoc = false;
    debugPrint('[cmcc] 第 $_attempt 次尝试（点刷新 + 等 '
        '${kCmccAttemptWait.inSeconds} 秒）');
    setState(() {
      _phase = CmccPhase.running;
      _status = '正在读数字（第 $_attempt 次）…';
    });
    // 点一下页面里的「点击刷新」：掌厅的数据要用户点一下才出，这一下会让页面
    // 重发余量请求，而钩子此刻必然已经就位（注入时机的应对，见文件头）
    try {
      await _driver?.pokeRefresh();
    } catch (_) {}
    _waitTimer?.cancel();
    _waitTimer = Timer(kCmccAttemptWait, () => unawaited(_afterAttempt()));
  }

  /// 一次尝试的等待窗口结束：没拿到可用读数就 reload 再来。
  ///
  /// ⚠️ 这里**不能**因为"钩到过响应"就提前收工：钩到的那个响应可能解不开、
  /// 也可能是字段变了，而页面还会调别的接口（getMainPlan 等）。所以窗口一到，
  /// 只要还没成功就继续重试，最后一次不行就降级到 B/D——否则一钩到坏响应，
  /// 整条链就**卡死在这儿**（既读不到数，也不给用户原因）。
  Future<void> _afterAttempt() async {
    _capturing = false;
    if (!mounted || _settled) return;
    if (_attempt < kCmccMaxAttempts) {
      final next = _attempt + 1;
      setState(() => _status = _capturedThisDoc
          ? '钩到了但没解出，重新加载再试（第 $next 次）…'
          : '这次没钩到，重新加载再试（第 $next 次）…');
      try {
        await _driver?.reload();
      } catch (_) {}
      return; // 等下一次 onPageFinished/文字消息把下一轮带起来
    }
    await _fallbackToText();
  }

  /// B：从页面文字里抠数字；抠不到 → D（只把页面留给用户）。
  Future<void> _fallbackToText() async {
    _capturing = false;
    if (_settled) return;
    final text = _lastText.trim();
    if (text.isNotEmpty) {
      final parsed = parsePageText(text);
      if (parsed.isOk) {
        await _settle(parsed.reading!, degraded: true);
        return;
      }
    }
    debugPrint('[cmcc] C 与 B 都没读成：$kCmccFailBoth');
    if (!mounted) return;
    setState(() {
      _phase = CmccPhase.failed;
      _settled = true;
      _status = '读不到数字';
      _reason = kCmccFailBoth;
    });
    await _recordFailure(kCmccFailBoth);
  }

  /// 成功：落库 + 记一条**自动来源**快照（喂既有差值算法）+ 排下一次轮询。
  Future<void> _settle(CmccReading reading, {bool degraded = false}) async {
    if (_settled) return;
    _settled = true;
    _capturing = false;
    _waitTimer?.cancel();
    final now = _now();
    debugPrint('[cmcc] 读到通用流量 ${reading.generalUsedGb}GB'
        '（定向 ${reading.directional?.usedGb ?? "没给"}），'
        '来源=${reading.source.name}');
    await _store.recordSuccess(reading, now);
    await _recordAutoSnapshot(reading.generalUsedGb, now);
    if (!mounted) return;
    setState(() {
      _reading = reading;
      _phase = CmccPhase.ok;
      _status = degraded ? '读到了（从页面文字里认出来的）' : '读到了（钩到接口响应）';
      _reason = null;
    });
    _schedulePoll();
  }

  /// 把自动读到的「通用流量已用」记成一条快照（`source = cmcc`）。
  ///
  /// 为什么记快照：既有的差值算法（两个快照相减 + 与本 App 移动流量相减 =
  /// **疑似免流**）就是这么用的，自动来源接进去后用户不用再手抄。
  /// 读不到 `generalUsedGb` 时**什么都不记**（不拿 0 冒充）——这是硬规矩。
  Future<void> _recordAutoSnapshot(double? generalUsedGb, DateTime now) async {
    if (generalUsedGb == null) return;
    if (!mayRecordAutoSnapshot(
      latest: TrafficSnapshotStore.instance.latest,
      now: now,
    )) {
      return; // 刚记过一条自动的（连着点两下刷新），不重复占名额
    }
    var appBytes = -1;
    try {
      final range = TrafficStatsService.monthRange(now);
      final r = await _traffic.queryMobile(from: range.from, to: range.to);
      final got = r.sample?.appBytes;
      if (got != null) appBytes = got;
    } catch (_) {
      // 读不到系统口径就记 -1（界面显示"本 App 读数不可用"），不挡快照
    }
    await TrafficSnapshotStore.instance.add(CarrierSnapshot(
      at: now,
      carrierGb: generalUsedGb,
      appMobileBytes: appBytes,
      source: SnapshotSource.cmcc,
    ));
  }

  /// 记一次失败（累加失败计数 → 退避），并排下一次。
  Future<void> _recordFailure(String reason) async {
    await _store.recordFailure(reason, _now());
    _schedulePoll();
  }

  /// 会话失效：停轮询、提示重登（**绝不自动重发验证码**）。
  Future<void> _stopForRelogin() async {
    debugPrint('[cmcc] 会话失效：停止自动轮询，等用户自己重登（不代发验证码）');
    _waitTimer?.cancel();
    _pollTimer?.cancel();
    _pollTimer = null;
    _settled = true;
    _capturing = false;
    if (mounted) {
      setState(() {
        _phase = CmccPhase.needLogin;
        _status = '登录态失效了';
        _reason = kCmccReloginReason;
      });
    }
    await _store.markNeedRelogin(kCmccReloginReason);
    // 这里**不排任何轮询**：needsRelogin=true 时 [cmccNextPollPlan] 也不给 delay，
    // 两道保险都指向"停下等用户自己重登"
  }

  /// 按策略排下一次自动查询（页面活着才排；需要重登 → 不排）。
  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final plan = _store.pollPlan;
    final delay = plan.delay;
    if (!plan.poll || delay == null) return;
    _pollTimer = Timer(delay, () {
      if (!mounted) return;
      unawaited(_resumeIfDue(force: true));
    });
  }

  /// 定时到点 / 回前台：再来一轮（不清失败计数，成功才清）。
  Future<void> _resumeIfDue({required bool force}) async {
    if (!mounted) return;
    if (_store.needsRelogin) return; // 需要重登 → 绝不自动再查
    if (!force && _store.reading == null && _store.failures == 0) return;
    if (_phase == CmccPhase.needLogin) return;
    // 正在一轮的等待窗口里就别插队（回前台会触发这里，插队等于把这次尝试作废）
    if (_capturing) return;
    _settled = false;
    _attempt = 0;
    _capturedThisDoc = false;
    await _beginCapture();
  }

  /// 用户手动点「重新读一次」。
  Future<void> _manualRetry() async {
    _waitTimer?.cancel();
    _settled = false;
    _capturing = false;
    _attempt = 0;
    _capturedThisDoc = false;
    if (!mounted) return;
    setState(() {
      _reason = null;
      _status = '重新读一次…';
    });
    if (_pageKind == CmccPageKind.login || !_homeSeen) {
      // 还在登录页：去首页（用户已登录的话，这一步就进数据页）
      try {
        await _driver?.start(kCmccHomeUrl);
      } catch (_) {}
      return;
    }
    await _beginCapture();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _driver?.controller;
    return Scaffold(
      appBar: AppBar(title: const Text(kCmccGroup)),
      body: Column(
        children: [
          _statusCard(theme),
          const Divider(height: 1),
          Expanded(
            child: controller == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '这个环境里没有 WebView（测试 / 组件异常）。'
                        '真机上这里会显示掌厅页面。',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : WebViewWidget(controller: controller),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final reading = _reading;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        key: kCmccPageStatusKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_status, style: theme.textTheme.titleSmall)),
              if (_phase == CmccPhase.running)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (reading != null) ...[
            const SizedBox(height: 6),
            Text(
              '通用流量已用 ${fmtCmccGb(reading.generalUsedGb)}'
              '${reading.source == CmccReadingSource.pageText ? '（页面文字）' : '（接口）'}',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              reading.directional?.usedGb == null
                  ? kCmccNoDirectional
                  : '定向流量已用 ${fmtCmccGb(reading.directional!.usedGb)}',
              style: small,
            ),
            Text('已记成一条自动快照，可回「流量计量」算差值。', style: small),
          ],
          if (_reason != null) ...[
            const SizedBox(height: 4),
            Text(
              _reason!,
              key: kCmccPageReasonKey,
              style: small?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (_phase == CmccPhase.needLogin) ...[
            const SizedBox(height: 4),
            Text(kCmccLoginHint, style: small),
          ],
          if (_phase == CmccPhase.failed) ...[
            const SizedBox(height: 4),
            Text(kCmccFallbackHint, style: small),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                key: kCmccPageRetryKey,
                onPressed: () => unawaited(_manualRetry()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新读一次'),
              ),
              if (_phase == CmccPhase.needLogin)
                FilledButton.tonal(
                  key: kCmccPageGoHomeKey,
                  onPressed: () => unawaited(_goHome()),
                  child: const Text('我已登录，去读数字'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(kCmccIntro, style: small),
        ],
      ),
    );
  }

  /// 「我已登录，去读数字」：直接加载首页。
  Future<void> _goHome() async {
    _settled = false;
    _capturing = false;
    _attempt = 0;
    _homeSeen = true;
    if (!mounted) return;
    setState(() {
      _reason = null;
      _status = '正在打开个人首页…';
    });
    try {
      await _driver?.start(kCmccHomeUrl);
    } catch (_) {}
  }
}

/// GB 显示（掌厅给的数最多两位小数，多给也没意义）。
///
/// null = **读不到**，显示 `—`（**不用 `0 GB` 冒充**：0 在流量语境里是"没用量"，
/// 与"没读到"是两件事）。
String fmtCmccGb(double? gb) =>
    gb == null ? '—' : '${gb.toStringAsFixed(2)} GB';
