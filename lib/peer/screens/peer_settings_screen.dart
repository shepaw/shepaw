import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/product_features.dart';
import '../../l10n/app_localizations.dart';
import '../../screens/storage_browser_screen.dart';
import '../../storage/store_protocol.dart' show TrustLevel;
import '../../storage/store_service.dart';
import '../../widgets/form_bottom_bar.dart';
import '../models/paired_peer.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import '../widgets/peer_store_share_panel.dart';
import 'peer_chat_screen.dart';
import '../widgets/peer_device_icon.dart';

/// P2P 设备设置页面
///
/// 可修改备注名称、查看设备信息、删除配对等。
class PeerSettingsScreen extends StatefulWidget {
  final PairedPeer peer;

  const PeerSettingsScreen({super.key, required this.peer});

  /// 返回 true 表示 peer 被删除了
  static Future<bool?> show(BuildContext context, PairedPeer peer) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PeerSettingsScreen(peer: peer)),
    );
  }

  @override
  State<PeerSettingsScreen> createState() => _PeerSettingsScreenState();
}

class _PeerSettingsScreenState extends State<PeerSettingsScreen> {
  late String _deviceName;
  late bool _isConnected;
  late String _trustLevel;
  bool _isMaster = false;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _deviceName = widget.peer.deviceName;
    _trustLevel = widget.peer.trustLevel;
    _isConnected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _refreshConnectionState();
    });
    _loadMaster();
  }

  Future<void> _loadMaster() async {
    final master = await StoreService.instance.masterDeviceId();
    if (!mounted) return;
    setState(() => _isMaster = master == widget.peer.fingerprint);
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    super.dispose();
  }

  void _refreshConnectionState() {
    final connected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    if (mounted && connected != _isConnected) {
      setState(() => _isConnected = connected);
    }
  }

  Future<void> _editName() async {
    final l10n = AppLocalizations.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: _deviceName);
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

    if (newName != null && newName.isNotEmpty && newName != _deviceName) {
      await PeerStorageService().updateDeviceName(widget.peer.id, newName);
      if (mounted) {
        setState(() => _deviceName = newName);
      }
    }
  }

  void _startChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PeerChatScreen(peer: widget.peer),
      ),
    );
  }

  void _browsePeerStorage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: widget.peer.fingerprint,
          deviceName: _deviceName,
          readOnly: true,
          peerId: widget.peer.id,
        ),
      ),
    );
  }

  Future<void> _changeTrustLevel() async {
    final l10n = AppLocalizations.of(context);
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.peerSettings_trustLevel),
        children: [
          RadioListTile<String>(
            title: Text(l10n.peerPairing_trustOwner),
            value: TrustLevel.owner,
            groupValue: _trustLevel,
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<String>(
            title: Text(l10n.peerPairing_trustFriend),
            value: TrustLevel.friend,
            groupValue: _trustLevel,
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
    );
    if (selected == null || selected == _trustLevel || !mounted) return;

    if (selected == TrustLevel.owner && _trustLevel == TrustLevel.friend) {
      final apply = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.peerSettings_trustLevel),
          content: Text(l10n.peerSettings_trustOwnerHint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.peerSettings_keepShares),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.peerSettings_applyOwnerDefaults),
            ),
          ],
        ),
      );
      await PeerStorageService().setTrustLevel(widget.peer.id, selected);
      if (apply == true) {
        await StoreService.instance.setOutboundStoreShares(
          widget.peer.id,
          PeerStorageService.ownerDefaultStoreShares(),
        );
      }
    } else if (selected == TrustLevel.friend) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.peerSettings_trustFriendHint)),
        );
      }
      await PeerStorageService().setTrustLevel(widget.peer.id, selected);
    } else {
      await PeerStorageService().setTrustLevel(widget.peer.id, selected);
    }

    if (mounted) setState(() => _trustLevel = selected);
    PeerConnectionManager.instance.notifyPeerListChanged();
  }

  void _openStoreSharePanel() {
    final l10n = AppLocalizations.of(context);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(l10n.peerStoreShare_panelTitle)),
          body: PeerStoreSharePanel(peerId: widget.peer.id),
        ),
      ),
    );
  }

  Future<void> _deletePeer() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.peerSettings_deletePairing),
        content: Text(l10n.peerSettings_deleteConfirm(_deviceName)),
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
      await PeerConnectionManager.instance.removePeer(widget.peer.id);
      if (mounted) {
        Navigator.of(context).pop(true); // 返回 true 表示已删除
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.peerSettings_title),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
          const SizedBox(height: 24),

          // 设备头像 + 名称
          Center(
            child: Column(
              children: [
                PeerDeviceIcon(peer: widget.peer, size: 80, borderRadius: 20),
                const SizedBox(height: 12),
                Text(
                  _deviceName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: _isConnected ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isConnected ? l10n.peerSettings_online : l10n.peerSettings_offline,
                      style: TextStyle(
                        color: _isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                    if (_isMaster) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          l10n.storage_masterBadge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // 设置项
          _buildSection(context, l10n.peerSettings_sectionBasic, [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(l10n.peerSettings_aliasName),
              subtitle: Text(_deviceName),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editName,
            ),
            if (_isMaster)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: Text(l10n.storage_masterNode),
                subtitle: Text(l10n.storage_nasPaired),
              ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l10n.peerSettings_fingerprint),
              subtitle: Text(_formatFingerprint(widget.peer.fingerprint)),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text(l10n.peerSettings_pairedAt),
              subtitle: Text(_formatDate(widget.peer.pairedAt)),
            ),
            if (widget.peer.pairingRole != null)
              ListTile(
                leading: Icon(
                  widget.peer.pairingRole == PeerPairingRole.initiator
                      ? Icons.call_made
                      : Icons.call_received,
                ),
                title: Text(l10n.peerSettings_connectionInitiator),
                subtitle: Text(
                  '${widget.peer.pairingRoleShortLabel(l10n)} · ${widget.peer.pairingRoleDescription(l10n)}',
                ),
              ),
          ]),

          const SizedBox(height: 16),

          _buildSection(context, l10n.storage_spaceSection, [
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(l10n.storage_peerSpaceEntry),
              subtitle: Text(l10n.storage_sharedBrowseHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: _browsePeerStorage,
            ),
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(l10n.peerStoreShare_panelTitle),
              subtitle: Text(l10n.peerStoreShare_panelHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openStoreSharePanel,
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(l10n.peerSettings_trustLevel),
              subtitle: Text(_trustLevel == TrustLevel.friend
                  ? l10n.peerPairing_trustFriend
                  : l10n.peerPairing_trustOwner),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changeTrustLevel,
            ),
          ]),

          const SizedBox(height: 16),

          _buildSection(context, l10n.peerSettings_sectionConnection, [
            if (widget.peer.localEndpoint != null)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(l10n.peerSettings_localAddress),
                subtitle: Text(widget.peer.localEndpoint!),
              ),
            if (widget.peer.channelEndpoint != null)
              ListTile(
                leading: const Icon(Icons.cloud),
                title: Text(l10n.peerSettings_relayAddress),
                subtitle: Text(widget.peer.channelEndpoint!),
              ),
            ListTile(
              leading: const Icon(Icons.lock),
              title: Text(l10n.peerSettings_encryption),
              subtitle: Text(l10n.peerSettings_encryptionValue),
            ),
          ]),

          const SizedBox(height: 24),

          // 危险操作
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: _deletePeer,
              icon: Icon(Icons.delete_forever, color: colorScheme.error),
              label: Text(l10n.peerSettings_deletePairing, style: TextStyle(color: colorScheme.error)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colorScheme.error),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),

          const SizedBox(height: 16),
              ],
            ),
          ),
          if (ProductFeatures.deviceChatUiEnabled)
            FormBottomBar(
              child: FormPrimaryButton(
                onPressed: _startChat,
                icon: Icons.chat_bubble_outline,
                label: l10n.peerSettings_startChat,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ),
        ...children,
      ],
    );
  }

  String _formatFingerprint(String fp) {
    final buffer = StringBuffer();
    for (var i = 0; i < fp.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(fp[i]);
    }
    return buffer.toString();
  }

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
