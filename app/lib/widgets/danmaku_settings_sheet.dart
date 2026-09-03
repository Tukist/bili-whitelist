/// 弹幕设置面板（BottomSheet 内容，v2.16.6+）：
/// 屏蔽类型（滚动/顶部/底部）+ 屏蔽关键词管理 + 全局透明度滑杆。
///
/// 自包含 StatefulWidget：内部持有编辑态，任何改动即时 [onChanged] 回传
/// 父层（播放页 setState 让渲染层生效 + 持久化）。父层通过 `showModalBottomSheet`
/// 挂载，外观与字幕设置面板同源（深色卡片）。
library;

import 'package:flutter/material.dart';

import '../models/danmaku_settings.dart';

/// 设置面板行内小标题样式。
const TextStyle _kSectionTitleStyle =
    TextStyle(color: Colors.white54, fontSize: 12);

class DanmakuSettingsSheet extends StatefulWidget {
  /// 当前设置（父层持有的值，作为编辑起点）。
  final DanmakuSettings initial;

  /// 任何改动即时回调（父层负责 setState 应用到渲染层 + 保存持久化）。
  final ValueChanged<DanmakuSettings> onChanged;

  const DanmakuSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  late DanmakuSettings _s = widget.initial;
  late final TextEditingController _wordCtrl = TextEditingController();

  @override
  void dispose() {
    _wordCtrl.dispose();
    super.dispose();
  }

  /// 编辑态变化 → 本地刷新 + 回传父层（父层同步渲染并持久化）。
  void _set(DanmakuSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  /// 添加屏蔽词（去空白；重复词由 normalizeWords 剔除）。
  void _addWord(String raw) {
    final word = raw.trim();
    if (word.isEmpty) return;
    final words = DanmakuSettings.normalizeWords([..._s.blockWords, word]);
    _wordCtrl.clear();
    _set(_s.copyWith(blockWords: words));
  }

  void _removeWord(String word) {
    _set(_s.copyWith(
      blockWords: DanmakuSettings.normalizeWords(
        _s.blockWords.where((w) => w != word),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Text('弹幕设置',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 14)),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            // ---- 屏蔽类型 ----
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              activeTrackColor: Colors.pinkAccent,
              title: const Text('滚动弹幕',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('从右向左飞过（默认开启）',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              value: !_s.blockScroll,
              onChanged: (v) => _set(_s.copyWith(blockScroll: !v)),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              activeTrackColor: Colors.pinkAccent,
              title: const Text('顶部弹幕',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('固定在顶部居中停留（默认开启）',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              value: !_s.blockTop,
              onChanged: (v) => _set(_s.copyWith(blockTop: !v)),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              activeTrackColor: Colors.pinkAccent,
              title: const Text('底部弹幕',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('固定在底部居中停留（默认开启）',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              value: !_s.blockBottom,
              onChanged: (v) => _set(_s.copyWith(blockBottom: !v)),
            ),
            const Divider(height: 12),
            // ---- 屏蔽关键词 ----
            const Text('屏蔽关键词', style: _kSectionTitleStyle),
            const SizedBox(height: 2),
            const Text('弹幕文本包含任一关键词即不显示（空词自动忽略）',
                style: TextStyle(color: Colors.white30, fontSize: 11)),
            const SizedBox(height: 8),
            if (_s.blockWords.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('未添加屏蔽词',
                    style: TextStyle(color: Colors.white24, fontSize: 12)),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final w in _s.blockWords)
                    InputChip(
                      label: Text(w,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      backgroundColor: const Color(0xFF3A3A3F),
                      deleteIconColor: Colors.white54,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => _removeWord(w),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _wordCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: Colors.pinkAccent,
              decoration: InputDecoration(
                hintText: '输入要屏蔽的词，回车添加',
                hintStyle:
                    const TextStyle(color: Colors.white30, fontSize: 13),
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF2A2A2E),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: _addWord,
            ),
            const Divider(height: 20),
            // ---- 透明度 ----
            Row(
              children: [
                const Text('透明度', style: _kSectionTitleStyle),
                const Spacer(),
                Text('${(_s.opacity * 100).round()}%',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            Slider(
              value: _s.opacity,
              min: kDanmakuOpacityMin,
              max: kDanmakuOpacityMax,
              divisions: 16,
              activeColor: Colors.pinkAccent,
              inactiveColor: Colors.white24,
              label: '${(_s.opacity * 100).round()}%',
              onChanged: (v) => _set(_s.copyWith(opacity: v)),
            ),
            // 透明度实时预览（示例文本 + 全局系数透明度）
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Opacity(
                opacity: _s.opacity,
                child: Container(
                  alignment: Alignment.center,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3F),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('示例弹幕：这就是 100% 的样子',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            const SizedBox(height: 2),
            const Text('透明度对全部弹幕生效（20%~100%），设置自动保存',
                style: TextStyle(color: Colors.white24, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
