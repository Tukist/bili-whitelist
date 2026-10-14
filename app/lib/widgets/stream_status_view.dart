/// 个人页「取流状态」（v2.53.0）：一眼看出**现在走的是哪条路**。
///
/// 用户原话：「我要怎么确定现在是普通模式还是免流模式」。App 侧能确定的只有
/// **取流模式**（走哪条接口 + 哪个 UA）—— 免流本身是运营商计费侧的事，App
/// 无法自证，所以这里只如实说两件事：
///
/// 1. **当前形态**（三态，缺一不可）：
///    - [kStreamModeWeb]：开关关着，走网页接口（默认、最稳）；
///    - [kStreamModeApp]：开关开着且本会话没回退过，走官方 App gRPC `PlayView`；
///    - [kStreamModeAppFallback]：开关**开着**但本会话已自动回退（[UiPrefsStore
///      .streamCompatSessionFallback]）—— 这一态必须能显示，否则用户看着开关
///      是开的，会一直以为在走 App 形态（回退是静默的、不改用户设置）；
/// 2. **最近一次取流的实测事实**（接口来源 / 清晰度档位 / 带没带登录 Cookie /
///    什么时候）—— 运行时才知道，所以由 [StreamStatusStore] 落盘，
///    重启后仍能看到上次结果。
///
/// 文案纪律：设置里的小字用户明确要求"不超过两行"（按非空白字符 ≤ 42 钉住，
/// 见 [kStreamModeHonestNote] 与 `test/stream_status_view_test.dart`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/playview_api.dart' show playViewQualityName;
import '../services/stream_status_store.dart';
import '../services/ui_prefs_store.dart';

/// 「取流状态」整块卡片的 key（测试锚点；v2.53.0）。
const Key kStreamStatusKey = Key('stream-status-card');

/// 当前形态那一行文字的 key（测试锚点；v2.53.0）。
const Key kStreamStatusModeKey = Key('stream-status-mode');

/// 三种形态的标题文字（v2.53.0）。
const String kStreamModeWeb = '普通模式（网页接口）';
const String kStreamModeApp = 'App 形态（实验）';
const String kStreamModeAppFallback = 'App 形态已在本会话回退';

/// 如实说明：这里只表示"App 走的是哪条接口"，不表示免流生效。
///
/// 为什么必须写：用户会把这个状态当成"免流已生效"，而**免流是运营商计费侧
/// 判定的**（同一份 App 流量，在 Wi-Fi 上不免、在指定套餐外不免、CDN 判定策略
/// 也可能变），App 无从自证。宁可把话说小，也别让用户拿一句"你在免流"去对账。
///
/// 长度：按非空白字符计 30 个（上限 42，用户要求小字两行）。
const String kStreamModeHonestNote = '免流是否生效只能看运营商侧；这里只表示 App 走的是哪条接口。';

/// 三态判定：开关 + 会话回退标记 → 标题文字。
///
/// **纯函数**（不读全局单例）是为了能被测试逐态钉住，也为了让判据与
/// `config.streamCompatInUse()` 显式对齐：那里为真 = 这里显示 [kStreamModeApp]。
String streamModeLabel({
  required bool enabled,
  required bool sessionFallback,
}) {
  if (!enabled) return kStreamModeWeb;
  return sessionFallback ? kStreamModeAppFallback : kStreamModeApp;
}

/// 「最近一次取流」那一行的文案；没有记录（或记录残缺）时返回 null。
///
/// 形如：`最近一次：App 形态 · 480P · 带登录 Cookie · 10-14 18:30`
String? lastStreamSummary({
  required StreamSource? source,
  required int quality,
  required bool hadLoginCookie,
  required DateTime? at,
}) {
  if (source == null || at == null) return null;
  final mode = switch (source) {
    StreamSource.app => 'App 形态',
    StreamSource.web => '网页接口',
  };
  final q = quality > 0 ? playViewQualityName(quality) : '清晰度未知';
  final cookie = hadLoginCookie ? '带登录 Cookie' : '未带登录 Cookie';
  return '最近一次：$mode · $q · $cookie · ${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// 「取流状态」块（内联在个人页「网络与播放」分区里，开关下方）。
///
/// 自己读 [UiPrefsStore]（形态）与 [StreamStatusStore]（最近一次事实）：
/// 两个都可能是"还没读盘"的状态，所以在 [State.initState] 里各触发一次
/// `ensureLoaded`（幂等，见各自 store 的说明）。
class StreamStatusView extends StatefulWidget {
  const StreamStatusView({super.key});

  @override
  State<StreamStatusView> createState() => _StreamStatusViewState();
}

class _StreamStatusViewState extends State<StreamStatusView> {
  @override
  void initState() {
    super.initState();
    // 幂等：启动流程通常已经读过；这里只是为了"直接从个人页进来"也不缺数据。
    // 读失败在 store 内部静默（降级成"没有记录"），不阻塞面板。
    unawaited(StreamStatusStore.instance.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      // 形态看 UiPrefsStore，最近一次事实看 StreamStatusStore —— 两个都要听，
      // 少听一个就会出现"回退了但卡片还写着 App 形态"（回退标记不落盘、
      // 只在内存里，不重建就没有第二次机会）。
      listenable: Listenable.merge(
          [UiPrefsStore.instance, StreamStatusStore.instance]),
      builder: (context, _) {
        final label = streamModeLabel(
          enabled: UiPrefsStore.instance.streamCompatEnabled,
          sessionFallback: UiPrefsStore.instance.streamCompatSessionFallback,
        );
        final store = StreamStatusStore.instance;
        final summary = lastStreamSummary(
          source: store.source,
          quality: store.quality,
          hadLoginCookie: store.hadLoginCookie,
          at: store.at,
        );
        return Container(
          key: kStreamStatusKey,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color:
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.swap_horiz,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      key: kStreamStatusModeKey,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              if (summary != null) ...[
                const SizedBox(height: 4),
                Text(
                  summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                kStreamModeHonestNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
