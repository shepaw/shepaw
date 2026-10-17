import 'package:flutter/material.dart';

import '../../clis/shepaw/os/os_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../services/approval/cli_audit_fold.dart';

/// In-chat card for CLI / OS tool confirmation.
class CliApprovalCard extends StatefulWidget {
  final Map<String, dynamic> actionData;
  final void Function(String confirmationId, String actionId, String actionLabel)?
      onActionSelected;

  const CliApprovalCard({
    super.key,
    required this.actionData,
    this.onActionSelected,
  });

  @override
  State<CliApprovalCard> createState() => _CliApprovalCardState();
}

class _CliApprovalCardState extends State<CliApprovalCard> {
  bool _rememberSession = false;

  String get _confirmationId =>
      widget.actionData['confirmation_id'] as String? ?? '';

  String get _toolName => widget.actionData['tool_name'] as String? ?? '';

  Map<String, dynamic> get _params {
    final flags = widget.actionData['flags'];
    if (flags is Map) return Map<String, dynamic>.from(flags);
    return const {};
  }

  String? get _selectedId =>
      widget.actionData['selected_action_id'] as String?;

  RiskLevel get _risk {
    final raw = widget.actionData['risk'] as String? ?? '';
    return RiskLevel.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => RiskLevel.lowRisk,
    );
  }

  bool get _isExpired => _selectedId == 'expired';

  bool get _hasSelection => _selectedId != null;

  bool get _canRememberSession => _risk != RiskLevel.highRisk && !_hasSelection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final highRisk = _risk == RiskLevel.highRisk;
    final approved = _selectedId == 'allow';
    final borderColor = _isExpired
        ? colorScheme.outlineVariant
        : _hasSelection
            ? (approved ? Colors.green.shade300 : Colors.orange.shade300)
            : highRisk
                ? colorScheme.error.withValues(alpha: 0.5)
                : colorScheme.primary.withValues(alpha: 0.4);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: highRisk
                  ? colorScheme.error.withValues(alpha: 0.08)
                  : colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _iconForTool(_toolName),
                  size: 18,
                  color: highRisk ? colorScheme.error : colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.osTool_confirmTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (highRisk && !_hasSelection)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      l10n.osTool_highRisk,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else if (_isExpired)
                  _statusChip(
                    l10n.osTool_expired,
                    colorScheme.surfaceContainerHighest,
                    colorScheme.onSurfaceVariant,
                  )
                else if (approved)
                  _statusChip(
                    l10n.osTool_approve,
                    Colors.green.shade100,
                    Colors.green.shade800,
                  )
                else if (_hasSelection)
                  _statusChip(
                    l10n.osTool_deny,
                    Colors.orange.shade100,
                    Colors.orange.shade800,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.osTool_tool}: $_toolName',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (CliAuditFold.formatParams(_params).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CliParamBlock(text: CliAuditFold.formatParams(_params)),
                ],
                if (_canRememberSession) ...[
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _rememberSession,
                    onChanged: (value) {
                      setState(() => _rememberSession = value ?? false);
                    },
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      l10n.osTool_rememberSession,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
                if (!_hasSelection) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => _respond('deny', l10n.osTool_deny),
                        child: Text(l10n.osTool_deny),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final actionId = _rememberSession && _canRememberSession
                              ? 'allow_session'
                              : 'allow';
                          _respond(actionId, l10n.osTool_approve);
                        },
                        style: highRisk
                            ? FilledButton.styleFrom(
                                backgroundColor: colorScheme.error,
                                foregroundColor: colorScheme.onError,
                              )
                            : null,
                        child: Text(l10n.osTool_approve),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _respond(String actionId, String label) {
    widget.onActionSelected?.call(_confirmationId, actionId, label);
  }

  Widget _statusChip(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  IconData _iconForTool(String name) {
    switch (name) {
      case 'shell_exec':
        return Icons.terminal;
      case 'file_read':
        return Icons.description;
      case 'file_write':
        return Icons.edit_document;
      case 'file_delete':
        return Icons.delete_forever;
      case 'file_move':
        return Icons.drive_file_move;
      case 'file_list':
        return Icons.folder_open;
      case 'app_open':
        return Icons.launch;
      case 'url_open':
        return Icons.open_in_browser;
      case 'screenshot':
        return Icons.screenshot;
      case 'clipboard_read':
        return Icons.content_paste;
      case 'clipboard_write':
        return Icons.content_copy;
      case 'system_info':
        return Icons.info_outline;
      case 'applescript_exec':
        return Icons.code;
      case 'process_list':
        return Icons.list_alt;
      case 'process_kill':
        return Icons.dangerous;
      case 'process_detail':
        return Icons.analytics;
      case 'network_connections':
        return Icons.lan;
      default:
        return Icons.build;
    }
  }
}

/// 同一条气泡里的 CLI 审计：已审工具默认折叠，待审的那一张展开在下面。
class CliToolAuditView extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final Map<String, dynamic>? pending;
  final void Function(String confirmationId, String actionId, String actionLabel)?
      onActionSelected;

  const CliToolAuditView({
    super.key,
    required this.entries,
    this.pending,
    this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entries.isNotEmpty) CliReviewedToolsFold(entries: entries),
        if (entries.isNotEmpty && pending != null) const SizedBox(height: 8),
        if (pending != null)
          CliApprovalCard(
            actionData: pending!,
            onActionSelected: onActionSelected,
          ),
      ],
    );
  }
}

/// 已审核工具列表。收起时只留一行计数，展开后每条是工具名加参数。
class CliReviewedToolsFold extends StatefulWidget {
  final List<Map<String, dynamic>> entries;

  const CliReviewedToolsFold({super.key, required this.entries});

  @override
  State<CliReviewedToolsFold> createState() => _CliReviewedToolsFoldState();
}

class _CliReviewedToolsFoldState extends State<CliReviewedToolsFold> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.osTool_auditFolded(widget.entries.length),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < widget.entries.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _ReviewedToolTile(entry: widget.entries[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ReviewedToolTile extends StatelessWidget {
  final Map<String, dynamic> entry;

  const _ReviewedToolTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final tool = (entry['tool_name'] as String?)?.trim() ?? '';
    final decision = (entry['decision'] as String?) ?? '';
    final rawParams = entry['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};
    final paramText = CliAuditFold.formatParams(params);
    final (label, bg, fg) = switch (decision) {
      'allow' => (
          l10n.osTool_approve,
          Colors.green.shade100,
          Colors.green.shade800,
        ),
      'deny' => (
          l10n.osTool_deny,
          Colors.orange.shade100,
          Colors.orange.shade800,
        ),
      'expired' => (
          l10n.osTool_expired,
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant,
        ),
      _ => (
          decision,
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant,
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tool,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        if (paramText.isNotEmpty) ...[
          const SizedBox(height: 4),
          _CliParamBlock(text: paramText),
        ],
      ],
    );
  }
}

class _CliParamBlock extends StatelessWidget {
  final String text;

  const _CliParamBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}
