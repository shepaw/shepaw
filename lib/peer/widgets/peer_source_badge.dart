import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../services/peer_storage_service.dart';

/// 来源配对设备的小徽标，用于 agent 名称旁标注共享来源设备。
class PeerSourceBadge extends StatefulWidget {
  final String? peerId;
  final String? fallbackName;
  final double maxWidth;

  const PeerSourceBadge({
    super.key,
    this.peerId,
    this.fallbackName,
    this.maxWidth = 120,
  });

  factory PeerSourceBadge.fromAgent(RemoteAgent agent, {double maxWidth = 120}) {
    return PeerSourceBadge(
      peerId: agent.sourcePeerId,
      fallbackName: agent.sourcePeerName,
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
    final label = _resolvedName ?? widget.fallbackName ?? l10n.peerPairing_title;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 11, color: colorScheme.primary),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Text(
              label,
              style: TextStyle(fontSize: 10, color: colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
