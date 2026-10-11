import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/agent_node.dart';
import '../../models/remote_agent.dart';
import '../services/peer_storage_service.dart';

/// 来源设备的小徽标，用于 agent 名称旁标注它跑在哪台设备上。
///
/// 工作节点上的 agent 经主机中继，来源连接是主机，徽标显示 [nodeName]。
class PeerSourceBadge extends StatefulWidget {
  final String? peerId;
  final String? fallbackName;
  final double maxWidth;

  /// 工作节点名，给了就不再按 [peerId] 查设备名。
  final String? nodeName;

  /// 所在节点离线时置灰。
  final bool offline;

  const PeerSourceBadge({
    super.key,
    this.peerId,
    this.fallbackName,
    this.maxWidth = 120,
    this.nodeName,
    this.offline = false,
  });

  factory PeerSourceBadge.forAgent({
    required String? peerId,
    required String? peerName,
    required Map<String, dynamic>? metadata,
    double maxWidth = 120,
  }) {
    final node = AgentNodeInfo.fromMetadata(metadata);
    return PeerSourceBadge(
      peerId: peerId,
      fallbackName: peerName,
      maxWidth: maxWidth,
      nodeName: node.onWorker ? node.nodeName ?? node.nodeId : null,
      offline: node.onWorker && !node.online,
    );
  }

  factory PeerSourceBadge.fromAgent(RemoteAgent agent, {double maxWidth = 120}) {
    return PeerSourceBadge.forAgent(
      peerId: agent.sourcePeerId,
      peerName: agent.sourcePeerName,
      metadata: agent.metadata,
      maxWidth: maxWidth,
    );
  }

  @override
  State<PeerSourceBadge> createState() => _PeerSourceBadgeState();
}

class _PeerSourceBadgeState extends State<PeerSourceBadge> {
  String? _resolvedName;

  @override
  void initState() {
    super.initState();
    _resolveName();
  }

  @override
  void didUpdateWidget(covariant PeerSourceBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId ||
        oldWidget.fallbackName != widget.fallbackName) {
      _resolveName();
    }
  }

  Future<void> _resolveName() async {
    String? name;
    final peerId = widget.peerId;
    if (peerId != null && peerId.isNotEmpty) {
      try {
        final peers = await PeerStorageService().loadAllPeers();
        for (final p in peers) {
          if (p.id == peerId && p.deviceName.isNotEmpty) {
            name = p.deviceName;
            break;
          }
        }
      } catch (_) {}
    }
    name ??= widget.fallbackName;
    if (mounted) setState(() => _resolvedName = name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final label = widget.nodeName ??
        _resolvedName ??
        widget.fallbackName ??
        l10n.peerPairing_title;
    final foreground =
        widget.offline ? colorScheme.onSurfaceVariant : colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: widget.offline
            ? colorScheme.surfaceContainerHighest
            : colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 11, color: foreground),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Text(
              label,
              style: TextStyle(fontSize: 10, color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
