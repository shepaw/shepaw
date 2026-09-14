import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/remote_agent.dart';
import '../../../services/she_service.dart';

/// 事件管理页顶部的 Agent 选择器。
///
/// 列表来自 `RemoteAgentService.getAllAgents()`；She 也在其中（持久化成普通
/// `RemoteAgent` 行，`id == SheService.sheId`），所以不需要额外做并集。
class EventAgentPicker extends StatelessWidget {
  final List<RemoteAgent> agents;
  final String? selectedAgentId;
  final ValueChanged<String?> onChanged;

  const EventAgentPicker({
    super.key,
    required this.agents,
    required this.selectedAgentId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: DropdownButtonFormField<String?>(
        key: const Key('event_agent_picker'),
        initialValue: agents.any((a) => a.id == selectedAgentId)
            ? selectedAgentId
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.eventMgmt_agentLabel,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.smart_toy_outlined),
          isDense: true,
        ),
        items: agents
            .map(
              (a) => DropdownMenuItem<String?>(
                value: a.id,
                child: Text(
                  a.id == SheService.sheId
                      ? SheService.resolveDisplayName(a.name, l10n.she_name)
                      : a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: onChanged,
      ),
    );
  }
}
