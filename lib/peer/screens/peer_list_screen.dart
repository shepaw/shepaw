import 'dart:async';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import 'peer_chat_screen.dart';
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
      if (mounted) {
        setState(() {
          _peers = peers;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已与 ${peer.deviceName} 配对成功')),
        );
      }
    }
  }

  void _openChat(PairedPeer peer) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PeerChatScreen(peer: peer),
      ),
    );
  }

  Future<void> _showPeerActions(PairedPeer peer) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('修改备注'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('删除配对', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: peer.deviceName);
        return AlertDialog(
          title: const Text('修改备注'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入备注名称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配对'),
        content: Text('确定要删除与 ${peer.deviceName} 的配对吗？\n所有消息记录也会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('配对设备'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加配对',
            onPressed: _startPairing,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _peers.isEmpty
              ? _buildEmptyState(colorScheme)
              : _buildPeerList(colorScheme),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
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
              '尚未配对任何设备',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '扫描对方的二维码或让对方扫描你的二维码来建立加密连接',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startPairing,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('开始配对'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerList(ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadPeers,
      child: ListView.builder(
        itemCount: _peers.length,
        itemBuilder: (context, index) {
          final peer = _peers[index];
          return _PeerListItem(
            peer: peer,
            onTap: () => _openChat(peer),
            onLongPress: () => _showPeerActions(peer),
          );
        },
      ),
    );
  }
}

class _PeerListItem extends StatelessWidget {
  final PairedPeer peer;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PeerListItem({
    required this.peer,
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
      title: Text(peer.deviceName),
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
