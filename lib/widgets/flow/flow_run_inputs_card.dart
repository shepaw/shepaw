import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 超过这个长度先收起，避免一条超长提示词把节点树顶到屏幕外。
/// 点「展开全文」看原文；短输入一开始就完整显示。
const int _previewLimit = 1200;

/// 执行详情的「初始输入」卡：把开跑表单里填的提示词 / 参数原样展示出来。
///
/// 主机把 `Run.inputs` 随 `flow_run_get_resp.inputs` 回填（老主机没有这个
/// 字段就没这张卡）。列表里的 `input_title` 只是截出来的第一行，不能代替原文。
/// 值可能是字符串、数字或嵌套 JSON，统一转成可读文本；只做本地展开状态。
class FlowRunInputsCard extends StatefulWidget {
  const FlowRunInputsCard({super.key, required this.inputs});

  final Map<String, dynamic> inputs;

  @override
  State<FlowRunInputsCard> createState() => _FlowRunInputsCardState();
}

class _FlowRunInputsCardState extends State<FlowRunInputsCard> {
  final Set<String> _expanded = <String>{};

  static String _text(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    try {
      return const JsonEncoder.withIndent('  ').convert(raw);
    } catch (_) {
      return raw.toString();
    }
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final entries = <MapEntry<String, String>>[];
    for (final entry in widget.inputs.entries) {
      final key = entry.key.trim();
      final value = _text(entry.value).trim();
      if (key.isEmpty || value.isEmpty) continue;
      entries.add(MapEntry(key, value));
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('run-inputs-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notes_outlined,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(l10n.flow_runInputsTitle,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.onSurface)),
            ],
          ),
          for (final entry in entries) ...[
            const SizedBox(height: 12),
            SelectableText(
              entry.key,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _expanded.contains(entry.key) || entry.value.length <= _previewLimit
                  ? entry.value
                  : '${entry.value.substring(0, _previewLimit)}…',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
            if (entry.value.length > _previewLimit)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: ValueKey('run-inputs-toggle-${entry.key}'),
                  onPressed: () => _toggle(entry.key),
                  child: Text(_expanded.contains(entry.key)
                      ? l10n.flow_runInputsCollapse
                      : l10n.flow_runInputsExpand),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
