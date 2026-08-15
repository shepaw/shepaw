import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../screens/chat_screen.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import '../../services/remote_agent_service.dart';
import '../../widgets/avatar_image.dart';
import '../services/peer_agent_client_service.dart';
import '../services/peer_connection_manager.dart';

/// Device-details section: list peer agents and toggle whether they appear
/// in this app. Start / stop / disable stay on the remote hub.
class PeerAgentManagePanel extends StatefulWidget {
  final String peerId;
  final bool isPeerConnected;

  const PeerAgentManagePanel({
    super.key,
    required this.peerId,
    required this.isPeerConnected,
  });

  @override
  State<PeerAgentManagePanel> createState() => _PeerAgentManagePanelState();
}

class _PeerAgentManagePanelState extends State<PeerAgentManagePanel> {
  List<PeerAgentManageEntry> _entries = const [];
  List<RemoteAgent> _localAgents = const [];
  bool _loading = true;
  String? _error;
  String? _busyId;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _load();
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _load(quiet: true);
    });
  }

  @override
  void didUpdateWidget(covariant PeerAgentManagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPeerConnected != widget.isPeerConnected) {
      _load();
    }
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _loading = true);
    final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
    final mine = all
        .where((a) =>
            a.protocol == ProtocolType.peer && a.sourcePeerId == widget.peerId)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    PeerAgentManageResult? remote;
    if (widget.isPeerConnected) {
      remote = await PeerAgentClientService.instance.manageAgents(
        peerId: widget.peerId,
        op: 'list',
      );
    }

    if (!mounted) return;
    setState(() {
      _localAgents = mine;
      _loading = false;
      if (remote == null) {
        _error = null;
        _entries = mine.map(_entryFromLocal).toList();
        return;
      }
      _error = remote.ok || remote.unsupported ? null : remote.error;
      if (remote.agents.isNotEmpty) {
        _entries = remote.agents;
      } else if (remote.ok || remote.unsupported) {
        _entries = mine.map(_entryFromLocal).toList();
      }
    });
  }

  PeerAgentManageEntry _entryFromLocal(RemoteAgent a) {
    return PeerAgentManageEntry(
      id: a.remoteAgentId ?? a.id,
      name: a.name,
      engine: (a.metadata['engine'] as String?) ?? '',
      running: a.peerAgentRunning,
      enabled: a.peerAgentEnabled,
      manageable: a.peerAgentManageable,
    );
  }

  RemoteAgent? _localFor(PeerAgentManageEntry entry) {
    return _localAgents.cast<RemoteAgent?>().firstWhere(
          (a) => a!.remoteAgentId == entry.id || a.id == entry.id,
          orElse: () => null,
        );
  }

  Future<void> _setVisibleOnApp(RemoteAgent local, bool visible) async {
    setState(() => _busyId = local.remoteAgentId ?? local.id);
    try {
      final latest =
          await getIt<LocalDatabaseService>().getRemoteAgentById(local.id) ??
              local;
      final metadata = Map<String, dynamic>.from(latest.metadata);
      if (visible) {
        metadata.remove('hidden_on_this_app');
      } else {
        metadata['hidden_on_this_app'] = true;
      }
      await getIt<RemoteAgentService>().updateAgent(
        latest.copyWith(metadata: metadata),
      );
      PeerConnectionManager.instance.notifyPeerListChanged();
      await _load(quiet: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  void _openChat(PeerAgentManageEntry entry) {
    final local = _localFor(entry);
    if (local == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          agentId: local.id,
          agentName: local.name,
          agentAvatar: local.avatar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            l10n.peerSettings_sectionAgents,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            l10n.peerSettings_agentVisibilityHint,
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              widget.isPeerConnected
                  ? l10n.peerSettings_noManagedAgents
                  : l10n.peerSettings_agentManageOffline,
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          )
        else
          ..._entries.map((entry) => _buildTile(l10n, entry)),
        if (_error != null && _error != 'timeout' && _error != 'offline')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.peerSettings_agentOpFailed(_error!),
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _buildTile(
    AppLocalizations l10n,
    PeerAgentManageEntry entry,
  ) {
    final local = _localFor(entry);
    final busy = _busyId == entry.id;
    final hidden = local?.hiddenOnThisApp ?? false;
    final String statusLabel;
    final Color statusColor;
    if (hidden) {
      statusLabel = l10n.peerSettings_agentHiddenOnApp;
      statusColor = Colors.grey;
    } else if (entry.manageable) {
      if (!entry.enabled) {
        statusLabel = l10n.peerSettings_agentDisabled;
        statusColor = Colors.grey;
      } else if (entry.running) {
        statusLabel = l10n.peerSettings_agentRunning;
        statusColor = Colors.green;
      } else {
        statusLabel = l10n.peerSettings_agentStopped;
        statusColor = Colors.orange;
      }
    } else if (local?.isOnline == true) {
      statusLabel = l10n.status_online;
      statusColor = Colors.green;
    } else {
      statusLabel = l10n.status_offline;
      statusColor = Colors.grey;
    }

    return ListTile(
      leading: AvatarImage(
        avatar: local?.avatar.isNotEmpty == true ? local!.avatar : '🤖',
        size: 40,
        borderRadius: 10,
        fallback: const Icon(Icons.smart_toy_outlined),
      ),
      title: Text(entry.name),
      subtitle: Text(
        [
          if (entry.engine.isNotEmpty) entry.engine,
          statusLabel,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: statusColor, fontSize: 12),
      ),
      onTap: local == null ? null : () => _openChat(entry),
      trailing: local == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Tooltip(
                  message: l10n.peerSettings_agentShowOnApp,
                  child: SizedBox(
                    height: 28,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Switch(
                        value: !hidden,
                        onChanged: busy
                            ? null
                            : (v) => _setVisibleOnApp(local, v),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
