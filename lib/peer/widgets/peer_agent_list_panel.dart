import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../widgets/avatar_image.dart';

/// 对端设备共享的 Agent 列表面板（布局参考 [SessionListPanel]）。
class PeerAgentListPanel extends StatelessWidget {
  final List<RemoteAgent> agents;
  final bool isLoading;
  final bool isPeerConnected;
  final ValueChanged<RemoteAgent>? onAgentTap;

  const PeerAgentListPanel({
    super.key,
    required this.agents,
    required this.isLoading,
    required this.isPeerConnected,
    this.onAgentTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        _buildHeader(l10n),
        const Divider(height: 1),
        Expanded(child: _buildBody(l10n)),
      ],
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    final title = agents.isNotEmpty
        ? l10n.peerSettings_connectableAgentsTitleCount(agents.length)
        : l10n.peerSettings_connectableAgentsTitle;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (isLoading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (agents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text(
                isPeerConnected
                    ? l10n.peerSettings_noPeerAgentsConnected
                    : l10n.peerSettings_noPeerAgentsOffline,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 6),
              Text(
                isPeerConnected
                    ? l10n.peerSettings_peerEnableExternalHint
                    : l10n.peerSettings_syncAgentsOnConnect,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: agents.length,
      itemBuilder: (context, index) {
        final agent = agents[index];
        return _PeerAgentTile(
          agent: agent,
          onTap: onAgentTap == null ? null : () => onAgentTap!(agent),
        );
      },
    );
  }
}

class _PeerAgentTile extends StatelessWidget {
  final RemoteAgent agent;
  final VoidCallback? onTap;

  const _PeerAgentTile({
    required this.agent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final online = agent.status == AgentStatus.online;

    return ListTile(
      leading: _buildAvatar(agent.avatar),
      title: Text(agent.name),
      subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
          ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: online ? Colors.green : Colors.grey),
          const SizedBox(width: 4),
          Text(
            online ? l10n.peerSettings_online : l10n.peerSettings_offline,
            style: TextStyle(
              fontSize: 12,
              color: online ? Colors.green : Colors.grey,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey[400]),
          ],
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _buildAvatar(String avatar) {
    final isPath = (avatar.startsWith('/') && !avatar.startsWith('http')) ||
        avatar.startsWith('http') ||
        AvatarImage.isAsset(avatar);
    if (isPath) {
      return AvatarImage(
        avatar: avatar,
        size: 40,
        borderRadius: 10,
        fallback: const Icon(Icons.smart_toy_outlined),
      );
    }
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.indigo[50],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        avatar.isNotEmpty ? avatar : '🤖',
        style: const TextStyle(fontSize: 20),
      ),
    );
  }
}
