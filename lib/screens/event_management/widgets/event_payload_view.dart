import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';

/// 折叠 + 截断的事件载荷视图。
///
/// 群事件 payload 内嵌整份 GroupEvent JSON（见 [EventBusStore] 的注释），
/// 直接塞进无界 `Column` 会把整页撑爆，所以默认只渲染 [collapsedChars] 个字符，
/// 展开后限高滚动。
class EventPayloadView extends StatefulWidget {
  final Map<String, dynamic> payload;

  /// 折叠态最大字符数。
  static const collapsedChars = 600;

  const EventPayloadView({super.key, required this.payload});

  @override
  State<EventPayloadView> createState() => _EventPayloadViewState();
}

class _EventPayloadViewState extends State<EventPayloadView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.payload.isEmpty) return const SizedBox.shrink();

    final text = const JsonEncoder.withIndent('  ').convert(widget.payload);
    final truncated = text.length > EventPayloadView.collapsedChars;
    final shown = (!_expanded && truncated)
        ? '${text.substring(0, EventPayloadView.collapsedChars)}…'
        : text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(6),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _expanded ? 260 : 200),
            child: SingleChildScrollView(
              child: SelectableText(
                shown,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
        if (truncated)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _expanded
                    ? AppLocalizations.of(context).eventMgmt_payloadCollapse
                    : AppLocalizations.of(context).eventMgmt_payloadExpand,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }
}
