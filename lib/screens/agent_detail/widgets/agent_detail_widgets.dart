import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../agent_detail_kind.dart';

/// 详情页 / 编辑页共用的小组件与卡片外观。

/// 统一的「描边卡片」。两个页面都用它，避免一处改一处不改。
Widget agentCard({
  required BuildContext context,
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.all(16),
}) {
  final colorScheme = Theme.of(context).colorScheme;
  return Card(
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: colorScheme.outlineVariant),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// 卡片标题行（图标 + 文字）。
Widget agentSectionTitle(
  BuildContext context, {
  required IconData icon,
  required String title,
  Widget? trailing,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  return Row(
    children: [
      Icon(icon, size: 18, color: colorScheme.primary),
      const SizedBox(width: 8),
      Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
      ),
      if (trailing != null) ...[const Spacer(), trailing],
    ],
  );
}

/// 标签 / 值一行。详情页的技术信息、运行设置摘要都用它。
class AgentInfoRow extends StatelessWidget {
  const AgentInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.grey[600],
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: valueStyle ?? const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// 顶部状态徽标。状态由 [AgentDetailStatus] 合成（见 `agent_detail_kind.dart`）。
class AgentStatusChip extends StatelessWidget {
  const AgentStatusChip({super.key, required this.status});

  final AgentDetailStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final brightness = Theme.of(context).brightness;
    final onlineColor = AppColors.onlineFor(brightness);
    final String label;
    final Color color;
    switch (status) {
      case AgentDetailStatus.hostOffline:
        label = l10n.status_offline;
        color = Colors.grey;
      case AgentDetailStatus.nodeOffline:
        label = l10n.agentDetail_nodeOffline;
        color = Colors.grey;
      case AgentDetailStatus.disabled:
        label = l10n.peerSettings_agentDisabled;
        color = Colors.grey;
      case AgentDetailStatus.stopped:
        label = l10n.peerSettings_agentStopped;
        color = Colors.orange;
      case AgentDetailStatus.running:
        label = l10n.peerSettings_agentRunning;
        color = onlineColor;
      case AgentDetailStatus.online:
        label = l10n.status_online;
        color = onlineColor;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「来自 {设备}」来源标识。
class AgentSourceChip extends StatelessWidget {
  const AgentSourceChip({super.key, required this.sourceName});

  final String sourceName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 14, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            l10n.agentDetail_fromSource(sourceName),
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
