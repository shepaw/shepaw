import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../peer/widgets/peer_source_badge.dart';
import '../../theme/app_theme.dart';
import '../../utils/layout_utils.dart';

/// Agent picker for adding a member to a group chat. Pair with
/// [LayoutUtils.showRightDrawer] on desktop or a full-screen [Scaffold] on mobile.
class AddGroupMemberPanel extends StatelessWidget {
  final List<RemoteAgent> availableAgents;
  final ValueChanged<RemoteAgent> onAgentTap;

  const AddGroupMemberPanel({
    super.key,
    required this.availableAgents,
    required this.onAgentTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    if (availableAgents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.chat_noMoreAgents,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.chat_addMember,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              ...availableAgents.map((agent) => ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(agent.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (agent.isPeerAgent) ...[
                      const SizedBox(width: 6),
                      PeerSourceBadge.fromAgent(agent),
                    ],
                  ],
                ),
                subtitle: agent.bio != null && agent.bio!.isNotEmpty
                    ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                onTap: () => onAgentTap(agent),
              )),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}
