import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/widgets/peer_source_badge.dart';
import '../services/she_service.dart';
import '../widgets/agent_list_avatar.dart';

/// 玉简指派 / 执行 Agent 的选择结果。
class JadeSlipAgentPick {
  const JadeSlipAgentPick({
    required this.id,
    required this.name,
    required this.avatar,
  });

  final String id;
  final String name;
  final String avatar;
}

/// 选择 Agent 的弹层：头像 + 设备标签 + 搜索过滤。
///
/// 玉简里三处选人（指派 pill、点「交给 Agent」、派发兜底）共用这一个入口，
/// 避免各写一遍弹层、样式与顺序还不一致。
Future<JadeSlipAgentPick?> showJadeSlipAgentPicker(
  BuildContext context, {
  required List<RemoteAgent> agents,
  String? currentAgentId,
  bool allowNone = false,
}) {
  return showDialog<JadeSlipAgentPick>(
    context: context,
    builder: (ctx) => _JadeSlipAgentPickerDialog(
      agents: agents,
      currentAgentId: currentAgentId,
      allowNone: allowNone,
    ),
  );
}

class _JadeSlipAgentPickerDialog extends StatefulWidget {
  const _JadeSlipAgentPickerDialog({
    required this.agents,
    this.currentAgentId,
    required this.allowNone,
  });

  final List<RemoteAgent> agents;
  final String? currentAgentId;
  final bool allowNone;

  @override
  State<_JadeSlipAgentPickerDialog> createState() =>
      _JadeSlipAgentPickerDialogState();
}

class _JadeSlipAgentPickerDialogState
    extends State<_JadeSlipAgentPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final q = _query.text.trim().toLowerCase();
    final agents = widget.agents.where((a) {
      if (q.isEmpty) return true;
      if (a.name.toLowerCase().contains(q)) return true;
      final device = a.sourcePeerName ?? '';
      return device.toLowerCase().contains(q);
    }).toList();
    final sheMatches =
        q.isEmpty || l10n.she_name.toLowerCase().contains(q);

    return AlertDialog(
      title: Text(l10n.jadeSlip_pickAgent),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.jadeSlip_searchAgent,
                prefixIcon: Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: agents.isEmpty && !sheMatches
                  ? Center(child: Text(l10n.jadeSlip_noAgentMatch(_query.text)))
                  : ListView(
                      children: [
                        if (widget.allowNone)
                          _AgentOptionRow(
                            avatar: '',
                            name: l10n.jadeSlip_assigneeNone,
                            selected: widget.currentAgentId == null ||
                                widget.currentAgentId!.isEmpty,
                            onTap: () => Navigator.pop(
                              context,
                              JadeSlipAgentPick(
                                id: '',
                                name: l10n.jadeSlip_assigneeNone,
                                avatar: '',
                              ),
                            ),
                          ),
                        if (sheMatches)
                          _AgentOptionRow(
                            avatar: SheService.sheAvatar,
                            name: l10n.she_name,
                            selected: widget.currentAgentId == SheService.sheId,
                            onTap: () => Navigator.pop(
                              context,
                              JadeSlipAgentPick(
                                id: SheService.sheId,
                                name: l10n.she_name,
                                avatar: SheService.sheAvatar,
                              ),
                            ),
                          ),
                        for (final agent in agents)
                          if (agent.id != SheService.sheId)
                            _AgentOptionRow(
                              avatar: agent.avatar,
                              name: agent.name,
                              deviceLabel: agent.isPeerAgent
                                  ? null
                                  : l10n.jadeSlip_deviceLocal,
                              badge: agent.isPeerAgent
                                  ? PeerSourceBadge.fromAgent(agent)
                                  : null,
                              selected: widget.currentAgentId == agent.id,
                              onTap: () => Navigator.pop(
                                context,
                                JadeSlipAgentPick(
                                  id: agent.id,
                                  name: agent.name,
                                  avatar: agent.avatar,
                                ),
                              ),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
      ],
    );
  }
}

class _AgentOptionRow extends StatelessWidget {
  const _AgentOptionRow({
    required this.avatar,
    required this.name,
    required this.selected,
    required this.onTap,
    this.deviceLabel,
    this.badge,
  });

  final String avatar;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  final String? deviceLabel;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              AgentListAvatar(avatar: avatar, name: name, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (badge != null) badge!,
              if (badge == null && deviceLabel != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    deviceLabel!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
