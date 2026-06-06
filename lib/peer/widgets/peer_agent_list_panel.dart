import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import '../../widgets/avatar_image.dart';
import '../models/paired_peer.dart';
import '../services/peer_agent_host_service.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';

/// Peer 设备 Agent 共享面板：Tab 切换「对方分享给我」与「我分享给对方」。
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

class _PeerAgentListPanelState extends State<PeerAgentListPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  List<RemoteAgent> _peerAgents = [];
  List<RemoteAgent> _shareableAgents = [];
  Map<String, bool> _shareDecisions = {};
  bool _peerAgentsLoading = true;
  bool _shareLoading = true;
  StreamSubscription<void>? _peerListSub;

  int get _sharedCount =>
      _shareableAgents.where((a) => _shareDecisions[a.id] == true).length;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0);
    _loadAll();
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _loadAll();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadPeerAgents(), _loadShareableAgents()]);
  }

  Future<void> _loadPeerAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final mine = all
          .where((a) =>
              a.protocol == ProtocolType.peer &&
              a.sourcePeerId == widget.peerId)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _peerAgents = mine;
          _peerAgentsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _peerAgentsLoading = false);
    }
  }

  Future<void> _loadShareableAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final shareable = all
          .where((a) => a.isLocal && a.allowExternalAccess)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final decisions = await PeerStorageService().getAgentShares(widget.peerId);
      if (mounted) {
        setState(() {
          _shareableAgents = shareable;
          _shareDecisions = decisions;
          _shareLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _shareLoading = false);
    }
  }

  Future<void> _toggleShare(RemoteAgent agent, bool shared) async {
    setState(() => _shareDecisions[agent.id] = shared);
    await PeerStorageService().setAgentShare(widget.peerId, agent.id, shared);
    if (PeerConnectionManager.instance.getPeerState(widget.peerId) ==
        PeerConnectionState.connected) {
      await PeerAgentHostService.instance.pushAgentList(widget.peerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
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
        TabBar(
          controller: _tabController,
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          tabs: [
            Tab(text: l10n.peerChat_tabFromPeerCount(_peerAgents.length)),
            Tab(text: l10n.peerChat_tabSharedByMeCount(_sharedCount)),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _PeerAgentsTab(
                agents: _peerAgents,
                isLoading: _peerAgentsLoading,
                isPeerConnected: widget.isPeerConnected,
                onAgentTap: widget.onPeerAgentTap,
              ),
              _MySharedAgentsTab(
                agents: _shareableAgents,
                shareDecisions: _shareDecisions,
                isLoading: _shareLoading,
                onToggleShare: _toggleShare,
              ),
            ],
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

class _MySharedAgentsTab extends StatelessWidget {
  final List<RemoteAgent> agents;
  final Map<String, bool> shareDecisions;
  final bool isLoading;
  final void Function(RemoteAgent agent, bool shared) onToggleShare;

  const _MySharedAgentsTab({
    required this.agents,
    required this.shareDecisions,
    required this.isLoading,
    required this.onToggleShare,
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
              Icon(Icons.ios_share, size: 48, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text(
                l10n.peerSettings_noShareableAgents,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.peerSettings_enableExternalAccessHint,
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
        final shared = shareDecisions[agent.id] == true;
        return _MySharedAgentTile(
          agent: agent,
          shared: shared,
          onToggle: (value) => onToggleShare(agent, value),
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
      leading: _AgentAvatar(avatar: agent.avatar),
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

class _MySharedAgentTile extends StatelessWidget {
  final RemoteAgent agent;
  final bool shared;
  final ValueChanged<bool> onToggle;

  const _MySharedAgentTile({
    required this.agent,
    required this.shared,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _AgentAvatar(avatar: agent.avatar),
      title: Text(agent.name),
      subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
          ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: SizedBox(
        height: 28,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Switch(
            value: shared,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

class _AgentAvatar extends StatelessWidget {
  final String avatar;

  const _AgentAvatar({required this.avatar});

  @override
  Widget build(BuildContext context) {
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
