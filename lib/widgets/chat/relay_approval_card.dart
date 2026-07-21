import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../../services/chat_service.dart';
import '../../services/dispatch/dispatch_service.dart';

/// She 代理审批卡（在 She↔用户 频道中渲染）。
///
/// agent 在 She 绑定中转会话里发出 `ui.actionConfirmation` 时，
/// DispatchService 把审批代理到这里：用户无需打开中转会话即可批准/拒绝，
/// 应答由 [DispatchService.respondToRelayApproval] 路由回执行频道。
///
/// pending 状态下会惰性地与中转会话对齐：若用户已直接在中转会话里
/// 处理过该确认（relay 消息上出现 selected_action_id），卡片显示已处理。
class RelayApprovalCard extends StatelessWidget {
  final Message message;

  const RelayApprovalCard({super.key, required this.message});

  Map<String, dynamic> get _payload =>
      message.metadata?['relay_approval'] as Map<String, dynamic>? ?? {};

  /// 与中转会话对齐审批状态；任何读取失败都按未对齐处理（保留 pending）。
  Future<String?> _relaySelectedLabel() async {
    try {
      final payload = _payload;
      final relayChannelId = payload['relay_channel_id'] as String? ?? '';
      final confirmationId = payload['confirmation_id'] as String? ?? '';
      if (relayChannelId.isEmpty || confirmationId.isEmpty) return null;
      final messages = await ChatService()
          .loadChannelMessages(relayChannelId, limit: 50);
      for (final m in messages.reversed) {
        final ac = m.metadata?['action_confirmation'];
        if (ac is Map && ac['confirmation_id'] == confirmationId) {
          if (ac['selected_action_id'] != null) {
            return ac['selected_action_label'] as String? ??
                ac['selected_action_id'] as String?;
          }
          return null;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final status = payload['status'] as String? ?? 'pending';
    final agentName = payload['agent_name'] as String? ?? '';
    final prompt = payload['prompt'] as String? ?? '';
    final selectedLabel = payload['selected_action_label'] as String? ?? '';
    final errorNote = payload['error_note'] as String? ?? '';

    if (status != 'pending') {
      return _buildShell(
        context,
        agentName: agentName,
        prompt: prompt,
        state: switch (status) {
          'resolved' => _CardState.resolved,
          'expired' => _CardState.expired,
          _ => _CardState.failed,
        },
        selectedLabel: selectedLabel,
        errorNote: errorNote,
      );
    }

    // pending：先按 metadata 渲染，再与中转会话对齐（用户可能已在
    // 中转会话里直接处理过）
    return FutureBuilder<String?>(
      future: _relaySelectedLabel(),
      builder: (context, snapshot) {
        final relayedLabel = snapshot.data;
        if (relayedLabel != null) {
          return _buildShell(
            context,
            agentName: agentName,
            prompt: prompt,
            state: _CardState.resolved,
            selectedLabel: relayedLabel,
          );
        }
        return _buildShell(
          context,
          agentName: agentName,
          prompt: prompt,
          state: _CardState.pending,
        );
      },
    );
  }

  Widget _buildShell(
    BuildContext context, {
    required String agentName,
    required String prompt,
    required _CardState state,
    String selectedLabel = '',
    String errorNote = '',
  }) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final payload = _payload;
    final actions = (payload['actions'] as List<dynamic>?) ?? const [];

    final (chipLabel, stateColor) = switch (state) {
      _CardState.pending => (l10n.relay_waiting, Colors.orange),
      _CardState.resolved => (l10n.relay_processed, Colors.green),
      _CardState.expired => (l10n.permission_statusExpired, Colors.grey),
      _CardState.failed => (l10n.relay_failed, Colors.red),
    };

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
                  Icon(Icons.verified_user_outlined,
                      size: 16, color: stateColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.relay_title(agentName),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _chip(chipLabel, stateColor),
                ],
              ),
            ),
            if (prompt.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  prompt,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ),
            if (state == _CardState.resolved && selectedLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  l10n.relay_yourChoice(selectedLabel),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.green[700]),
                ),
              ),
            if (state == _CardState.failed && errorNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  errorNote,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.red[400]),
                ),
              ),
            if (state == _CardState.pending && actions.isNotEmpty) ...[
              const Divider(height: 1, indent: 12, endIndent: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final action in actions)
                      _actionButton(context, action, l10n),
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

  Widget _actionButton(
    BuildContext context,
    dynamic action,
    AppLocalizations l10n,
  ) {
    if (action is! Map) return const SizedBox.shrink();
    final id = action['id']?.toString() ?? '';
    final label = action['label']?.toString() ?? id;
    if (id.isEmpty) return const SizedBox.shrink();

    final denyish = _looksLikeDeny(id, l10n) || _looksLikeDeny(label, l10n);
    final style = denyish
        ? OutlinedButton.styleFrom(visualDensity: VisualDensity.compact)
        : FilledButton.styleFrom(
            backgroundColor: Colors.green,
            visualDensity: VisualDensity.compact,
          );
    final onPressed = () =>
        DispatchService.instance.respondToRelayApproval(message.id, id, label);

    return denyish
        ? OutlinedButton(onPressed: onPressed, style: style, child: Text(label))
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: const Icon(Icons.check_circle_outline, size: 15),
            label: Text(label),
          );
  }

  static bool _looksLikeDeny(String s, AppLocalizations l10n) {
    final l = s.toLowerCase();
    return l.contains('deny') ||
        l.contains('reject') ||
        l.contains('cancel') ||
        l.contains('decline') ||
        l.contains('no') ||
        s == l10n.update_action_decline ||
        s == l10n.common_cancel ||
        s == l10n.peerApproval_deny;
  }

  Widget _chip(String label, Color color) {
    final textColor = color is MaterialColor ? color[800]! : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
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

enum _CardState { pending, resolved, expired, failed }
