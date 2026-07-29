import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/dispatch_task.dart';
import '../../models/message.dart';
import '../../screens/chat_screen.dart';
import '../../services/dispatch/dispatch_service.dart';

/// She 任务派发状态卡（在 She↔用户 频道中渲染）。
///
/// 数据全部来自系统消息的 metadata（dispatch_status），状态更新由
/// DispatchService 原地改写消息完成，卡片本身无状态。
class DispatchStatusCard extends StatelessWidget {
  final Message message;

  const DispatchStatusCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final meta = message.metadata ?? const {};
    final status = meta['status'] as String? ?? DispatchTask.statusRunning;
    final agentName = meta['target_agent_name'] as String? ?? '';
    final targetChannelId = meta['target_channel_id'] as String?;
    final promptPreview = meta['prompt_preview'] as String? ?? '';
    final awaiting = meta['awaiting_confirmation'] == true;
    final confirmTitle = meta['confirmation_title'] as String? ?? '';

    final (icon, label, color) = switch ((status, awaiting)) {
      (DispatchTask.statusDone, _) =>
        (Icons.check_circle_outline, l10n.dispatch_completed, Colors.green),
      (DispatchTask.statusTimeout, _) =>
        (Icons.timer_off_outlined, l10n.dispatch_timeout, Colors.deepOrange),
      (DispatchTask.statusError, _) =>
        (Icons.error_outline, l10n.dispatch_failed, Colors.red),
      (_, true) =>
        (Icons.touch_app_outlined, l10n.dispatch_waitingConfirm, Colors.blue),
      _ => (Icons.hourglass_top_outlined, l10n.dispatch_running, Colors.orange),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.45), width: 1.2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.send_outlined, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.dispatch_title(agentName),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusChip(label: label, color: color),
                ],
              ),
            ),
            if (promptPreview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  promptPreview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
            if (awaiting && confirmTitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  l10n.dispatch_pendingConfirm(confirmTitle),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.blue[700]),
                ),
              ),
            if (targetChannelId != null && targetChannelId.isNotEmpty) ...[
              const Divider(height: 1, indent: 12, endIndent: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ChatScreen(channelId: targetChannelId),
                          ),
                        );
                      },
                      icon: Icon(
                        awaiting ? Icons.touch_app_outlined : Icons.open_in_new,
                        size: 15,
                      ),
                      label: Text(
                        awaiting
                            ? l10n.dispatch_goConfirm
                            : l10n.dispatch_viewDetails,
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// She 派发确认卡：目标 agent 标记了 `dispatch_confirm` 时，
/// 由 DispatchService.requestConfirmation 写入；按钮回调
/// DispatchService.respondToConfirm（确认后直接发起派发）。
class DispatchConfirmCard extends StatelessWidget {
  final Message message;

  const DispatchConfirmCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final payload =
        message.metadata?['dispatch_confirm'] as Map<String, dynamic>? ?? {};
    final status = payload['status'] as String? ?? 'pending';
    final agentName = payload['agent_name'] as String? ?? '';
    final task = payload['task'] as String? ?? '';
    final pending = status == 'pending';
    final confirmed = status == 'confirmed';
    final stateColor = pending
        ? Colors.orange
        : (confirmed ? Colors.green : Colors.grey);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: stateColor.withOpacity(0.45), width: 1.2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: stateColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.dispatch_confirmTitle(agentName),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusChip(
                    label: pending
                        ? l10n.dispatch_awaitingConfirm
                        : (confirmed
                            ? l10n.dispatch_confirmed
                            : l10n.dispatch_cancelled),
                    color: stateColor,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                task,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
            if (pending) ...[
              const Divider(height: 1, indent: 12, endIndent: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => DispatchService.instance
                            .respondToConfirm(message.id, false),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(l10n.common_cancel),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => DispatchService.instance
                            .respondToConfirm(message.id, true),
                        icon: const Icon(Icons.check_circle_outline, size: 15),
                        label: Text(l10n.dispatch_confirmDispatch),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// She DM jump card: bound group session needs master review.
class GroupApprovalBridgeCard extends StatelessWidget {
  final Message message;

  const GroupApprovalBridgeCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final payload =
        message.metadata?['group_approval_bridge'] as Map<String, dynamic>? ??
            {};
    final groupName = payload['group_name'] as String? ?? '';
    final groupChannelId = payload['group_channel_id'] as String? ?? '';
    final interactionType = payload['interaction_type'] as String? ?? '';
    final agentName = payload['agent_name'] as String? ?? '';

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.withOpacity(0.55), width: 1.2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.rule_folder_outlined,
                      size: 16, color: Colors.amber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.group_approvalBridgeTitle(groupName),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusChip(
                    label: l10n.group_approvalBridgePending,
                    color: Colors.amber,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                l10n.group_approvalBridgeBody(
                  agentName.isNotEmpty ? agentName : 'She',
                  _interactionLabel(l10n, interactionType),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
            if (groupChannelId.isNotEmpty) ...[
              const Divider(height: 1, indent: 12, endIndent: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ChatScreen(channelId: groupChannelId),
                          ),
                        );
                      },
                      icon: const Icon(Icons.open_in_new, size: 15),
                      label: Text(l10n.group_approvalBridgeOpen),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  static String _interactionLabel(AppLocalizations l10n, String type) {
    switch (type) {
      case 'plan_approval':
        return l10n.group_approvalKindPlan;
      case 'action_confirmation':
        return l10n.group_approvalKindAction;
      case 'form':
        return l10n.group_approvalKindForm;
      case 'single_select':
      case 'multi_select':
        return l10n.group_approvalKindSelect;
      case 'file_upload':
        return l10n.group_approvalKindUpload;
      default:
        return type;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final chipColor = color;
    final textColor = chipColor is MaterialColor ? chipColor[800]! : chipColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: chipColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
