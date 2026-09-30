import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/layout_utils.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import '../../widgets/agent_list_avatar.dart';
import '../services/peer_connection_manager.dart';

/// 这台 Hub 经 peer 同步过来的 Agent。App 不往外分享自己的 Agent。
class PeerAgentListPanel extends StatefulWidget {
  final String peerId;
  final bool isPeerConnected;
  final ValueChanged<RemoteAgent>? onPeerAgentTap;

  const PeerAgentListPanel({
    super.key,
    required this.peerId,
    required this.isPeerConnected,
    this.onPeerAgentTap,
  });

  @override
  State<PeerAgentListPanel> createState() => _PeerAgentListPanelState();
}

class _PeerAgentListPanelState extends State<PeerAgentListPanel> {
  List<RemoteAgent> _peerAgents = [];
  bool _loading = true;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _loadPeerAgents();
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _loadPeerAgents();
    });
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPeerAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final mine = all
          .where((a) =>
              a.protocol == ProtocolType.peer &&
              a.sourcePeerId == widget.peerId &&
              !a.hiddenOnThisApp)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _peerAgents = mine;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        if (LayoutUtils.isDesktopLayout(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.peerChat_agentList,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _PeerAgentsTab(
            agents: _peerAgents,
            isLoading: _loading,
            isPeerConnected: widget.isPeerConnected,
            onAgentTap: widget.onPeerAgentTap,
          ),
        ),
      ],
    );
  }
}

class _PeerAgentsTab extends StatelessWidget {
  final List<RemoteAgent> agents;
  final bool isLoading;
  final bool isPeerConnected;
  final ValueChanged<RemoteAgent>? onAgentTap;

  const _PeerAgentsTab({
    required this.agents,
    required this.isLoading,
    required this.isPeerConnected,
    this.onAgentTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

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
    return ListTile(
      leading: _AgentAvatar(avatar: agent.avatar, name: agent.name),
      title: Text(agent.name),
      subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
          ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: onTap != null
          ? Icon(Icons.chevron_right, size: 18, color: Colors.grey[400])
          : null,
      onTap: onTap,
    );
  }
}

class _AgentAvatar extends StatelessWidget {
  final String avatar;
  final String name;

  const _AgentAvatar({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    return AgentListAvatar(avatar: avatar, name: name);
  }
}
