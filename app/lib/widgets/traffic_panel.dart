/// 个人页「流量计量」（v2.53.0 起）：**系统口径**（App 自己能读的）+ **运营商口径**
/// 两个来源对照。
///
/// 用户原话：「可不可以在个人界面加一个剩余免费流量计量」「需要同时有读自己的
/// 移动数据用量和运营商通用流量用量，相减得结果」。
///
/// ## 先说清楚能做什么、不能做什么（这个模块的全部设计前提）
///
/// - **运营商侧没有官方接口**：三大运营商都没有公开接口或授权给第三方 App
///   （都是封闭的营业厅/自家 App 接口）。所以：
///   - v2.53.0 的办法是**用户自己抄一个数**（手动录入）；
///   - v2.54.0 新增**自动来源**：在 App 内 WebView 里登一次中国移动掌厅
///     （`wx.10086.cn`），从页面自己调的那些接口里读「通用流量已用」
///     （`lib/pages/cmcc_page.dart` + `lib/services/cmcc_plan.dart`）。
///     这是**非官方接口**、随时可能失效，所以**手动录入一直留着兜底**，
///     界面上也必须能看出这次数字是自动读到的还是手填的；
/// - **系统侧能读**（需「使用情况访问」这个特殊权限）：本 App 的移动数据用量
///   （按 UID 聚合，**Wi-Fi 天然排除**）+ 本机总移动流量（device 口径）作对照；
/// - **相减给出来的是"疑似"**：本机统计 vs 运营商计费口径本来就有出入（计费延迟、
///   四舍五入、系统统计不覆盖全部流量、别的 App 同时在用通用流量），所以界面上
///   一律写"疑似/≈"并附口径说明，**不给斩钉截铁的"你免了 X GB"**。
///
/// ## 三个口径各自怎么来
///
/// 1. **系统**：[TrafficStatsService]（原生 `NetworkStatsManager`，只查
///    `TYPE_MOBILE`）。本月口径 = 本地月初 00:00 → 现在；没开权限时给
///    "一句话 + 一个「去开启」按钮"（[kTrafficPermissionLine]），绝不静默失败、
///    也不刷屏报错；
/// 2. **运营商（自动，v2.54.0）**：掌厅抓取成功自动记一条 `source = cmcc` 的快照
///    （读不到时**什么都不记**，不拿 0 冒充）；
/// 3. **运营商（手动，兜底）**：用户在输入框里填运营商 App 显示的「通用流量已用」
///    （GB）→「记录快照」（[TrafficSnapshotStore]，落盘，重启后还在）→ 最近两条
///    并排 →「算差值」得到：运营商通用增量、本 App 移动增量、**疑似免流**。
///
/// 文案纪律：设置里的小字用户要求"不超过两行"（所有导出常量按非空白字符 ≤ 42
/// 钉住，见 `test/traffic_panel_test.dart` 与本版新增的 `test/cmcc_panel_test.dart`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../cache/download_manager.dart' show fmtBytes;
import '../pages/cmcc_page.dart';
import '../services/cmcc_plan.dart';
import '../services/cmcc_session_store.dart';
import '../services/traffic_snapshot_store.dart';
import '../services/traffic_stats_service.dart';
import 'app_snack.dart';

/// 「流量计量」整块的 key（测试锚点；v2.53.0）。
const Key kTrafficPanelKey = Key('traffic-panel');

/// 「刷新」按钮的 key。
const Key kTrafficRefreshKey = Key('traffic-refresh');

/// 「去开启」（使用情况访问）按钮的 key。
const Key kTrafficGrantKey = Key('traffic-grant-usage-access');

/// 「通用流量已用」输入框的 key。
const Key kTrafficCarrierInputKey = Key('traffic-carrier-input');

/// 「记录快照」按钮的 key。
const Key kTrafficRecordKey = Key('traffic-record-snapshot');

/// 「算差值」按钮的 key。
const Key kTrafficDiffButtonKey = Key('traffic-diff-button');

/// 差值结果块的 key（没算之前不存在）。
const Key kTrafficDiffKey = Key('traffic-diff-result');

/// 快照卡片（较早 / 最近）的 key。
const Key kTrafficOlderSnapshotKey = Key('traffic-snapshot-older');
const Key kTrafficLatestSnapshotKey = Key('traffic-snapshot-latest');

/// 「中国移动掌厅（实验）」分组的 key（v2.54.0）。
const Key kTrafficCmccGroupKey = Key('traffic-cmcc-group');

/// 「打开掌厅页面」按钮的 key。
const Key kTrafficCmccOpenKey = Key('traffic-cmcc-open');

/// 「清除本机手机号」按钮的 key。
const Key kTrafficCmccForgetKey = Key('traffic-cmcc-forget');

/// 掌厅分组里"上次自动更新"那一行的 key。
const Key kTrafficCmccReadingKey = Key('traffic-cmcc-reading');

/// 掌厅登录状态那一行的 key。
const Key kTrafficCmccStateKey = Key('traffic-cmcc-state');

// ---- 掌厅分组的文案（按非空白字符 ≤ 42，见 test/cmcc_panel_test.dart）----

/// 「打开掌厅页面」按钮文案。
const String kCmccOpenButton = '打开掌厅页面';

/// 打开按钮上面那句：说清要点一次登录。
const String kCmccOpenHint = '在里面登录一次（手机号 + 短信验证码，可能要过滑块）。';

/// 手机号那一行的标签。
const String kCmccPhoneLabel = '掌厅账号';

/// 还不知道尾号时的值。
const String kCmccPhoneUnknown = '还不知道';

/// 「上次自动更新」标签。
const String kCmccLastUpdateLabel = '上次自动更新';

/// 从来没读到过时的值（**不要写"读不到"**：系统口径那边已经用过这三个字，
/// 同一个屏幕里出现两次会让"哪一项读不到"分不清）。
const String kCmccNeverRead = '还没读到过';

/// 自动读数会记快照、能跟手动录入一起算差值的说明。
const String kCmccAutoSnapshotHint = '自动读到的数会记成快照，和手动录入一起算差值。';

/// 手动兜底仍在的提示（指下面那一组）。
const String kCmccManualStillHere = '读不到也没关系：下面的手动录入一直可用。';

/// 「清除本机手机号」按钮文案。
const String kCmccForgetPhoneButton = '清除本机手机号';

/// 快照来源标记：自动读到的那条。
const String kCmccSourceAutoBadge = '自动读到（掌厅）';

/// 快照来源标记：用户手抄的那条。
const String kCmccSourceManualBadge = '手填的';

/// 清除后的提示（说清它**不**退出掌厅登录，避免用户误解）。
const String kCmccForgetPhoneSnack = '已清除本机记录（掌厅登录状态没动）。';

/// 分区小字：先说清"额度读不到"，再说清这里给的是什么。
///
/// v2.54.0 起运营商数值**可以自动读**（掌厅，「中国移动掌厅（实验）」那一组），
/// 手填只是兜底 —— 所以这句话改成"自动或手填"，不再只说手填（口径说明本身
/// 不能过期）。原句（v2.53.0）："免流额度读不到；这里用系统统计对照你手填的
/// 运营商数值。"，现按非空白字符计 32 个（上限 42，`contains('读不到')` 仍成立）。
const String kTrafficHint = '免流额度读不到；这里用系统统计对照运营商侧的数值（自动或手填）。';

/// 系统口径分组标题。
const String kTrafficSystemGroup = '系统口径（不含 Wi-Fi）';

/// 权限没开时的那**一句话**（配一个「去开启」按钮，不静默失败）。
///
/// 按非空白字符计 22 个（上限 42）。
const String kTrafficPermissionLine = '需要「使用情况访问」权限才能读本机流量统计。';

/// 运营商口径小字：告诉用户"两次快照"这个用法。
///
/// 按非空白字符计 22 个（上限 42）。
const String kTrafficSnapshotHint = '看视频前后各记一次，就能对比这段时间的增量。';

/// 口径与不确定性说明（**必须显示**：这是"不许斩钉截铁"的界面侧一半）。
///
/// 按非空白字符计 29 个（上限 42）。
const String kTrafficCaveat = '系统统计与运营商账单口径不同，仅供参考，以运营商账单为准。';

/// 差值块的补充说明：其它 App 同时在用通用流量时差值会失真。
///
/// 按非空白字符计 24 个（上限 42）。
const String kTrafficDiffCaveat = '其它 App 也在用通用流量时，差值会偏小甚至为负。';

/// 输入为空时的友好提示。
const String kTrafficInputEmpty = '先在上面填一个数：运营商 App 里的「通用流量已用」。';

/// 输入看不懂时的友好提示（形如 `12.34`）。
const String kTrafficInputInvalid = '这个数看不懂，请填成 12.34 这样（单位 GB）。';

/// 「运营商口径」分组标题。
const String kTrafficCarrierGroup = '运营商口径（手动录入）';

/// 输入框标签。
const String kTrafficCarrierInputLabel = '通用流量已用（GB）';

/// 输入框标签上面那句：数字从哪抄。
const String kTrafficCarrierSource = '数字从运营商 App 的「通用流量」页抄过来。';

/// GB 显示（两位小数，与"12.34 GB"这种抄写精度一致）。
String fmtGb(double gb) => '${gb.toStringAsFixed(2)} GB';

/// 带符号的 GB（差值用；负数不显示成 `+-0.35 GB`）。
String fmtSignedGb(double gb) =>
    '${gb < 0 ? '-' : '+'}${gb.abs().toStringAsFixed(2)} GB';

/// 快照时间（`10-14 18:30`）。
String fmtSnapshotTime(DateTime t) =>
    '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// 时长（`1 小时 3 分` / `12 分` / `45 秒`，够用就好）。
String fmtSpan(Duration d) {
  final s = d.inSeconds.abs();
  if (s < 60) return '$s 秒';
  final m = s ~/ 60;
  if (m < 60) return '$m 分';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '$h 小时' : '$h 小时 $rest 分';
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// 「流量计量」块（内联在个人页「网络与播放」分区之后）。
class TrafficPanel extends StatefulWidget {
  const TrafficPanel({super.key});

  @override
  State<TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<TrafficPanel> with WidgetsBindingObserver {
  static const TrafficStatsService _service = TrafficStatsService();

  final TextEditingController _input = TextEditingController();

  /// 本月的系统口径读数（null = 这次没读成，看 [_queryError]）。
  MobileTrafficSample? _month;
  String? _queryError;

  /// 是否已开「使用情况访问」（null = 还没查过）。
  bool? _hasAccess;

  /// 免权限的兜底对照（自开机以来的本机移动流量）。
  int? _sinceBoot;

  bool _loading = false;
  DateTime? _refreshedAt;
  String? _inputError;

  /// 「算差值」算出来的结果（点了才有；快照变了就作废，见 [_record]）。
  TrafficDiff? _diff;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 幂等：启动流程通常已经读过；直接从个人页进来时也不缺数据
    unawaited(TrafficSnapshotStore.instance.ensureLoaded());
    unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }

  /// 从系统设置页回来时自动重读一次。
  ///
  /// 为什么需要：用户点「去开启」→ 在系统设置里打开权限 → 切回 App，
  /// 这时候不重读的话他会看到"还是没权限"，等于白跑一趟（还得自己找刷新按钮）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  /// 重读：权限状态 + 本月系统口径 + 免权限兜底。**永不抛**（服务层全兜住）。
  ///
  /// 「正在读」时直接返回：回到前台与手动点刷新可能同时触发，读同一份数据
  /// 没必要叠两次（值一样、只是白打两次原生调用）。
  Future<void> refresh() async {
    if (_loading) return;
    if (mounted) setState(() => _loading = true);
    final access = await _service.hasUsageAccess();
    final now = DateTime.now();
    final range = TrafficStatsService.monthRange(now);
    final result = await _service.queryMobile(from: range.from, to: range.to);
    final boot = await _service.mobileSinceBoot();
    if (!mounted) return;
    setState(() {
      _hasAccess = access;
      _month = result.sample;
      _queryError = result.error;
      _sinceBoot = boot;
      _refreshedAt = now;
      _loading = false;
    });
  }

  /// 「去开启」：跳系统「使用情况访问」设置页；拉不起来就给一句人话（不静默）。
  Future<void> _openUsageAccessSettings() async {
    final ok = await _service.openUsageAccessSettings();
    if (!mounted || ok) return;
    AppSnack.show(
      context,
      '打不开系统设置页：请到「设置 → 应用 → 特殊应用权限 → 使用情况访问」里手动开启',
      kind: SnackKind.info,
    );
  }

  /// 记一条快照（运营商数值 + 此刻的系统读数，能在差值里用上）。
  ///
  /// 输入非法 → 就地给友好提示（[kTrafficInputEmpty] / [kTrafficInputInvalid]），
  /// **不记垃圾快照**；记成功清空输入框，并把上一次算出的差值作废
  /// （快照变了，旧结果再看就会误导）。
  Future<void> _recordSnapshot() async {
    final raw = _input.text;
    final gb = tryParseCarrierGb(raw);
    if (gb == null) {
      setState(() => _inputError =
          raw.trim().isEmpty ? kTrafficInputEmpty : kTrafficInputInvalid);
      return;
    }
    await TrafficSnapshotStore.instance.add(CarrierSnapshot(
      at: DateTime.now(),
      carrierGb: gb,
      appMobileBytes: _month?.appBytes ?? -1,
    ));
    if (!mounted) return;
    setState(() {
      _inputError = null;
      _diff = null;
      _input.clear();
    });
    AppSnack.show(context, '已记录快照：${fmtGb(gb)}', kind: SnackKind.info);
  }

  /// 「算差值」：拿最近两条快照算（少一条就什么都不做，按钮本来就不显示）。
  void _calcDiff() {
    final list = TrafficSnapshotStore.instance.snapshots;
    if (list.length < 2) return;
    setState(() {
      _diff = diffSnapshots(list[list.length - 2], list.last);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      key: kTrafficPanelKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('流量计量', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(kTrafficHint, style: small),
        const SizedBox(height: 12),
        // ---- 系统口径（App 真能读到的）----
        Text(kTrafficSystemGroup, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        _kvLine(
          theme,
          '本 App 移动流量（本月）',
          _month?.appBytes == null ? '读不到' : fmtBytes(_month!.appBytes!),
        ),
        const SizedBox(height: 2),
        _kvLine(
          theme,
          '本机总移动流量（本月）',
          _month?.deviceBytes == null ? '读不到' : fmtBytes(_month!.deviceBytes!),
        ),
        if (_hasAccess == false) ...[
          const SizedBox(height: 6),
          Text(kTrafficPermissionLine, style: small),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            key: kTrafficGrantKey,
            onPressed: _openUsageAccessSettings,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('去开启'),
          ),
          // 没权限时的兜底对照：至少有个"自开机以来"的数（如实标注，不冒充本月）
          if (_sinceBoot != null) ...[
            const SizedBox(height: 6),
            _kvLine(theme, '本机移动流量（自开机）', fmtBytes(_sinceBoot!)),
          ],
        ],
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            // 「刷新」按钮在读取中禁用：连点不该叠出几次并发查询
            OutlinedButton.icon(
              key: kTrafficRefreshKey,
              onPressed: _loading ? null : () => unawaited(refresh()),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(_loading ? '读取中…' : '刷新'),
            ),
            if (_refreshedAt != null)
              Text('更新于 ${fmtSnapshotTime(_refreshedAt!)}', style: small),
          ],
        ),
        if (_queryError != null) ...[
          const SizedBox(height: 4),
          Text(
            _queryError!,
            style: small?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),
        // ---- 中国移动掌厅（实验，v2.54.0）：自动读运营商数值 ----
        //
        // 放在"系统口径"和"手动录入"中间：它是**自动来源**，但**不可靠**
        // （非官方接口），所以下面那组手动录入必须一直留着——这里给出的所有
        // 状态都如实呈现（登录态 / 尾号 / 上次更新时间 / 失败原因 / 轮询计划），
        // 读不到时不显示 0 冒充。
        _cmccGroup(theme, small),
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),
        // ---- 运营商口径（手动录入，兜底）----
        Text(kTrafficCarrierGroup, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(kTrafficCarrierSource, style: small),
        const SizedBox(height: 4),
        Text(kTrafficSnapshotHint, style: small),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: kTrafficCarrierInputKey,
                controller: _input,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: kTrafficCarrierInputLabel,
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton(
                key: kTrafficRecordKey,
                onPressed: _recordSnapshot,
                child: const Text('记录快照'),
              ),
            ),
          ],
        ),
        if (_inputError != null) ...[
          const SizedBox(height: 6),
          Text(
            _inputError!,
            style: small?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 10),
        // 快照区跟着 store 走 → 单独监听
        ListenableBuilder(
          listenable: TrafficSnapshotStore.instance,
          builder: (context, _) {
            final list = TrafficSnapshotStore.instance.snapshots;
            if (list.isEmpty) return const SizedBox.shrink();
            final hasTwo = list.length >= 2;
            final older = hasTwo ? list[list.length - 2] : list.last;
            final latest = list.last;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _snapshotCard(
                        theme,
                        hasTwo ? '快照 1（较早）' : '快照 1（最近）',
                        older,
                        kTrafficOlderSnapshotKey,
                      ),
                    ),
                    if (hasTwo) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: _snapshotCard(
                          theme,
                          '快照 2（最近）',
                          latest,
                          kTrafficLatestSnapshotKey,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (hasTwo)
                  FilledButton.tonal(
                    key: kTrafficDiffButtonKey,
                    onPressed: _calcDiff,
                    child: const Text('算差值'),
                  )
                else
                  Text('再记一次就能对比增量。', style: small),
                if (_diff != null) ...[
                  const SizedBox(height: 8),
                  _diffBlock(theme, _diff!),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => unawaited(_undoSnapshot()),
                  child: const Text('删掉最新一条'),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _undoSnapshot() async {
    await TrafficSnapshotStore.instance.removeLatest();
    if (!mounted) return;
    setState(() => _diff = null); // 快照没了，旧差值必须一起作废
  }

  /// 一行「标签 —— 数值」。
  Widget _kvLine(ThemeData theme, String label, String value, {Key? key}) {
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      key: key,
      children: [
        Expanded(child: Text(label, style: style)),
        Text(value, style: style),
      ],
    );
  }

  /// 「中国移动掌厅（实验）」分组（v2.54.0）。
  ///
  /// 显示的全是**事实**：登录态、尾号、上次自动更新的时刻与来源（接口 / 页面
  /// 文字）、通用/定向已用、失败原因、轮询计划（多久读一次 / 为什么停了）。
  /// 读不到的项显示 `—` 或「还没读到过」，**不显示 0 冒充**。
  Widget _cmccGroup(ThemeData theme, TextStyle? small) {
    return ListenableBuilder(
      listenable: CmccSessionStore.instance,
      builder: (context, _) {
        final store = CmccSessionStore.instance;
        final reading = store.reading;
        return Column(
          key: kTrafficCmccGroupKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kCmccGroup, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(kCmccIntro, style: small),
            const SizedBox(height: 6),
            _kvLine(
              theme,
              kCmccPhoneLabel,
              store.phoneTail ?? kCmccPhoneUnknown,
            ),
            const SizedBox(height: 2),
            _kvLine(
              theme,
              '登录状态',
              cmccLoginStateLabel(store.loginState),
              key: kTrafficCmccStateKey,
            ),
            const SizedBox(height: 2),
            if (reading == null)
              _kvLine(
                theme,
                kCmccLastUpdateLabel,
                kCmccNeverRead,
                key: kTrafficCmccReadingKey,
              )
            else ...[
              _kvLine(
                theme,
                kCmccLastUpdateLabel,
                '${fmtSnapshotTime(reading.at)}'
                    '（${reading.source == CmccReadingSource.pageText ? '页面文字' : '接口'}）',
                key: kTrafficCmccReadingKey,
              ),
              const SizedBox(height: 2),
              _kvLine(theme, '通用流量已用', fmtCmccGb(reading.generalUsedGb)),
              const SizedBox(height: 2),
              _kvLine(
                theme,
                '定向流量已用',
                reading.hasDirectional
                    ? fmtCmccGb(reading.directionalUsedGb)
                    : '—',
              ),
              if (!reading.hasDirectional) ...[
                const SizedBox(height: 2),
                // 掌厅没给定向读数 → 如实说，**不显示 0** 冒充"有定向但没用"
                Text(kCmccNoDirectional, style: small),
              ],
            ],
            if (store.lastError != null) ...[
              const SizedBox(height: 4),
              Text(
                store.lastError!,
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 4),
            Text(store.pollPlan.reason, style: small),
            const SizedBox(height: 4),
            Text(kCmccAutoSnapshotHint, style: small),
            Text(kCmccManualStillHere, style: small),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: kTrafficCmccOpenKey,
                  onPressed: () => unawaited(_openCmccPage()),
                  icon: const Icon(Icons.language, size: 18),
                  label: const Text(kCmccOpenButton),
                ),
                if (store.phoneTail != null)
                  TextButton(
                    key: kTrafficCmccForgetKey,
                    onPressed: () => unawaited(_forgetCmccPhone()),
                    child: const Text(kCmccForgetPhoneButton),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(kCmccOpenHint, style: small),
          ],
        );
      },
    );
  }

  /// 打开掌厅抓取页（路线 C/B/D 都在那个页面里；它自己会把结果写回 store）。
  Future<void> _openCmccPage() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const CmccCapturePage(),
    ));
    // 回来时刷新一下本块（自动快照可能刚加了一条）
    if (mounted) setState(() {});
  }

  /// 清掉本机记的掌厅手机号（**不退出掌厅登录**：WebView 里的 Cookie 不动，
  /// 因为按域清 cookie 在部分 WebView 上清不干净，全清又会误伤 B 站登录态）。
  Future<void> _forgetCmccPhone() async {
    await CmccSessionStore.instance.forgetPhone();
    if (!mounted) return;
    AppSnack.show(context, kCmccForgetPhoneSnack, kind: SnackKind.info);
  }

  /// 一张快照卡：时间 / 来源（自动 or 手填） / 运营商数值 / （有的话）系统读数。
  Widget _snapshotCard(
      ThemeData theme, String title, CarrierSnapshot s, Key key) {
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Container(
      key: key,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: small),
          const SizedBox(height: 2),
          Text(fmtSnapshotTime(s.at), style: small),
          const SizedBox(height: 2),
          // 来源必须看得见（v2.54.0）：自动读到 vs 手抄，判断可信度时这是关键
          Text(
            s.isAuto ? kCmccSourceAutoBadge : kCmccSourceManualBadge,
            style: small,
          ),
          const SizedBox(height: 2),
          Text('通用 ${fmtGb(s.carrierGb)}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            s.hasAppReading ? '本 App ${fmtBytes(s.appMobileBytes)}' : '本 App 读数不可用',
            style: small,
          ),
        ],
      ),
    );
  }

  /// 差值块：两个口径的增量 + **疑似免流** + 口径说明与不确定性。
  Widget _diffBlock(ThemeData theme, TrafficDiff d) {
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final appDelta = d.appDeltaBytes;
    return Container(
      key: kTrafficDiffKey,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('两次快照相隔 ${fmtSpan(d.span)}', style: small),
          const SizedBox(height: 4),
          _kvLine(theme, '运营商通用增量', fmtSignedGb(d.carrierDeltaGb)),
          const SizedBox(height: 2),
          _kvLine(
            theme,
            '本 App 移动增量',
            appDelta == null ? '读不到' : fmtBytes(appDelta),
          ),
          const SizedBox(height: 2),
          _kvLine(
            theme,
            '疑似免流',
            d.suspectFreeGb == null ? '算不出' : '≈ ${fmtGb(d.suspectFreeGb!)}',
          ),
          if (!d.plausible) ...[
            const SizedBox(height: 4),
            Text('这两个数看起来对不上（可能换月重置或抄错了）。', style: small),
          ],
          const SizedBox(height: 4),
          Text(kTrafficDiffCaveat, style: small),
          Text(kTrafficCaveat, style: small),
        ],
      ),
    );
  }
}
