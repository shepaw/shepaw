import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../screens/chat_screen.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import '../../widgets/avatar_image.dart';
import '../services/peer_agent_client_service.dart';
import '../services/peer_connection_manager.dart';

/// Device-details section: list peer agents and (on Hub) enable / start / stop.
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
  bool _unsupported = false;
  String? _error;
  String? _busyId;
  StreamSubscription<void>? _peerListSub;

  bool get _manageable => _entries.any((e) => e.manageable);

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
        _unsupported = false;
        _error = null;
        _entries = mine
            .map((a) => PeerAgentManageEntry(
                  id: a.remoteAgentId ?? a.id,
                  name: a.name,
                  engine: (a.metadata['engine'] as String?) ?? '',
                  running: a.peerAgentRunning,
                  enabled: a.peerAgentEnabled,
                  manageable: a.peerAgentManageable,
                ))
            .toList();
        return;
      }
      _unsupported = remote.unsupported;
      _error = remote.ok ? null : remote.error;
      if (remote.agents.isNotEmpty) {
        _entries = remote.agents;
      } else if (remote.ok || remote.unsupported) {
        _entries = mine
            .map((a) => PeerAgentManageEntry(
                  id: a.remoteAgentId ?? a.id,
                  name: a.name,
                  engine: (a.metadata['engine'] as String?) ?? '',
                  running: a.peerAgentRunning,
                  enabled: a.peerAgentEnabled,
                  manageable: a.peerAgentManageable,
                ))
            .toList();
      }
    });
  }

  Future<void> _runOp({
    required String op,
    required String agentId,
    bool? enabled,
  }) async {
    if (!widget.isPeerConnected) return;
    setState(() => _busyId = agentId);
    final result = await PeerAgentClientService.instance.manageAgents(
      peerId: widget.peerId,
      op: op,
      agentId: agentId,
      enabled: enabled,
    );
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _error = result.ok ? null : result.error;
      if (result.agents.isNotEmpty) _entries = result.agents;
    });
  }

  void _openChat(PeerAgentManageEntry entry) {
    final local = _localAgents.cast<RemoteAgent?>().firstWhere(
          (a) => a!.remoteAgentId == entry.id || a.id == entry.id,
          orElse: () => null,
        );
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
          ..._entries.map((entry) => _buildTile(context, l10n, colorScheme, entry)),
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
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    PeerAgentManageEntry entry,
  ) {
    final local = _localAgents.cast<RemoteAgent?>().firstWhere(
          (a) => a!.remoteAgentId == entry.id || a.id == entry.id,
          orElse: () => null,
        );
    final busy = _busyId == entry.id;
    final canManage = _manageable && !_unsupported && widget.isPeerConnected;
    final statusLabel = !entry.enabled
        ? l10n.peerSettings_agentDisabled
        : entry.running
            ? l10n.peerSettings_agentRunning
            : l10n.peerSettings_agentStopped;
    final statusColor = !entry.enabled
        ? Colors.grey
        : entry.running
            ? Colors.green
            : Colors.orange;

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
      trailing: canManage
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 28,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Switch(
                      value: entry.enabled,
                      onChanged: busy
                          ? null
                          : (v) => _runOp(
                                op: 'set_enabled',
                                agentId: entry.id,
                                enabled: v,
                              ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (busy)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: entry.running
                        ? l10n.peerSettings_agentStop
                        : l10n.peerSettings_agentStart,
                    icon: Icon(
                      entry.running ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                      color: entry.running
                          ? colorScheme.error
                          : (entry.enabled ? Colors.green : Colors.grey),
                    ),
                    onPressed: !entry.enabled
                        ? null
                        : () => _runOp(
                              op: entry.running ? 'stop' : 'start',
                              agentId: entry.id,
                            ),
                  ),
              ],
            )
          : (local != null
              ? Icon(Icons.chevron_right, size: 18, color: Colors.grey[400])
              : null),
    );
  }
}
