import 'dart:async';
import 'package:flutter/material.dart';

import '../../config/product_features.dart';
import '../../l10n/app_localizations.dart';
import '../../storage/store_service.dart';
import '../models/paired_peer.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import 'peer_chat_screen.dart';
import 'peer_settings_screen.dart';
import '../widgets/peer_device_icon.dart';
import 'peer_pairing_screen.dart';

/// 已配对设备列表页
class PeerListScreen extends StatefulWidget {
  const PeerListScreen({super.key});

  @override
  State<PeerListScreen> createState() => _PeerListScreenState();
}

class _PeerListScreenState extends State<PeerListScreen> {
  List<PairedPeer> _peers = [];
  String? _masterId;
  bool _loading = true;
  StreamSubscription? _eventSub;

  @override
  void initState() {
    super.initState();
    _loadPeers();
    // 实时监听连接状态变化
    _eventSub = PeerConnectionManager.instance.events.listen((_) {
      _loadPeers();
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPeers() async {
    setState(() => _loading = true);
    try {
      final peers = await PeerConnectionManager.instance.getAllPeers();
      final master = await StoreService.instance.masterDeviceId();
      if (mounted) {
        setState(() {
          _peers = peers;
          _masterId = master;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _startPairing() async {
    final peer = await PeerPairingScreen.show(context);
    if (peer != null) {
      _loadPeers();
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.peerList_pairedSuccess(peer.deviceName))),
        );
      }
    }
  }

  void _openPeer(PairedPeer peer) {
    if (ProductFeatures.deviceChatUiEnabled) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PeerChatScreen(peer: peer),
        ),
      );
      return;
    }
    PeerSettingsScreen.show(context, peer);
  }

  Future<void> _showPeerActions(PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(l10n.peerList_editAlias),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text(
                l10n.peerSettings_deletePairing,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == 'rename') {
      await _renamePeer(peer);
    } else if (action == 'delete') {
      await _removePeer(peer);
    }
  }

  Future<void> _renamePeer(PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: peer.deviceName);
        return AlertDialog(
          title: Text(l10n.peerSettings_editAliasTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.peerSettings_editAliasHint,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(l10n.common_save),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != peer.deviceName) {
      await PeerStorageService().updateDeviceName(peer.id, newName);
      _loadPeers();
    }
  }

  Future<void> _removePeer(PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.peerSettings_deletePairing),
        content: Text(l10n.peerSettings_deleteConfirm(peer.deviceName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await PeerConnectionManager.instance.removePeer(peer.id);
      _loadPeers();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.peerPairing_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.peerList_add,
            onPressed: _startPairing,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _peers.isEmpty
              ? _buildEmptyState(colorScheme, l10n)
              : _buildPeerList(colorScheme, l10n),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.devices_other,
              size: 64,
              color: colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.contacts_noPeers,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.peerList_emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startPairing,
              icon: const Icon(Icons.qr_code_2),
              label: Text(l10n.contacts_startPairing),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerList(ColorScheme colorScheme, AppLocalizations l10n) {
    return RefreshIndicator(
      onRefresh: _loadPeers,
      child: ListView.builder(
        itemCount: _peers.length,
        itemBuilder: (context, index) {
          final peer = _peers[index];
          return _PeerListItem(
            peer: peer,
            isMaster: _masterId == peer.fingerprint,
            masterLabel: l10n.storage_masterBadge,
            onTap: () => _openPeer(peer),
            onLongPress: () => _showPeerActions(peer),
          );
        },
      ),
    );
  }
}

class _PeerListItem extends StatelessWidget {
  final PairedPeer peer;
  final bool isMaster;
  final String masterLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PeerListItem({
    required this.peer,
    required this.isMaster,
    required this.masterLabel,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Stack(
        children: [
          PeerDeviceIcon(peer: peer, size: 40, borderRadius: 20),
          // 在线状态指示器
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _stateColor(peer.state, colorScheme),
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              peer.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isMaster) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                masterLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        peer.state.listStatusLabel(l10n),
        style: TextStyle(
          color: _stateColor(peer.state, colorScheme),
          fontSize: 12,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }

  Color _stateColor(PeerConnectionState state, ColorScheme colorScheme) {
    switch (state) {
      case PeerConnectionState.connected:
        return Colors.green;
      case PeerConnectionState.connecting:
        return Colors.orange;
      case PeerConnectionState.disconnected:
        return colorScheme.onSurfaceVariant;
    }
  }

}
