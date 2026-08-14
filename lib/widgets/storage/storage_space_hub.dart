import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/screens/peer_pairing_screen.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/widgets/peer_device_icon.dart';
import '../../screens/storage_browser_screen.dart';
import '../../screens/storage_shared.dart';
import '../../screens/storage_snapshots_screen.dart';
import '../../screens/storage_space_settings_screen.dart';
import '../../storage/device_identity.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';
import '../../storage/sync_engine.dart';
import '../../theme/app_theme.dart';

/// 储物袋空间：扁平展示本机 + 配对共享设备。
///
/// 移动端：点击 push 进入对应空间。
/// 桌面 [embedded]：选中回调由父级在右侧 master-detail 展示。
class StorageSpaceHub extends StatefulWidget {
  final int? localUsedBytes;
  final bool embedded;

  /// Embedded：是否高亮「本机」。
  final bool localSelected;

  /// Embedded：当前选中的配对 peer id（[PairedPeer.id]）。
  final String? selectedPeerId;

  /// Embedded：是否高亮「备份与恢复」。
  final bool snapshotsSelected;

  final VoidCallback? onLocalSelected;
  final ValueChanged<PairedPeer>? onPeerSelected;
  final VoidCallback? onSnapshotsSelected;

  /// 追加在列表底部的入口。
  final List<Widget> footer;

  const StorageSpaceHub({
    super.key,
    this.localUsedBytes,
    this.embedded = false,
    this.localSelected = false,
    this.selectedPeerId,
    this.snapshotsSelected = false,
    this.onLocalSelected,
    this.onPeerSelected,
    this.onSnapshotsSelected,
    this.footer = const [],
  });

  @override
  State<StorageSpaceHub> createState() => StorageSpaceHubState();
}

class StorageSpaceHubState extends State<StorageSpaceHub> {
  static const double _avatarSize = 36;

  List<PairedPeer> _peers = const [];
  String? _masterId;
  String _selfId = '';
  bool _loading = true;
  String? _busyFp;
  int? _usedBytes;
  StreamSubscription<dynamic>? _peerEventsSub;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _usedBytes = widget.localUsedBytes;
    _peerEventsSub = PeerConnectionManager.instance.events.listen((_) {
      unawaited(reload());
    });
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      unawaited(reload());
    });
    unawaited(reload());
  }

  @override
  void didUpdateWidget(covariant StorageSpaceHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.localUsedBytes != oldWidget.localUsedBytes &&
        widget.localUsedBytes != null) {
      _usedBytes = widget.localUsedBytes;
    }
  }

  @override
  void dispose() {
    _peerEventsSub?.cancel();
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> reload() async {
    try {
      await PeerConnectionManager.instance.start();
      final peers = await PeerConnectionManager.instance.getAllPeers();
      final master = await StoreService.instance.masterDeviceId();
      final self = await DeviceIdentity.deviceId();
      final used = widget.localUsedBytes ?? await _loadUsedBytes(self);
      if (!mounted) return;
      setState(() {
        _peers = _sortedPeers(peers);
        _masterId = master;
        _selfId = self;
        _usedBytes = used;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<int?> _loadUsedBytes(String selfId) async {
    try {
      final store = await StoreService.instance.localStore();
      final stats = await store.stats();
      final devices = (stats['devices'] as Map?)?.cast<String, dynamic>() ?? {};
      final mine = (devices[selfId] as Map?)?.cast<String, dynamic>() ?? {};
      var total = 0;
      for (final space in StoreSpace.all) {
        total += mine[space] as int? ?? 0;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  List<PairedPeer> _sortedPeers(List<PairedPeer> peers) {
    final copy = List<PairedPeer>.from(peers);
    copy.sort((a, b) {
      final aOnline = _isConnected(a);
      final bOnline = _isConnected(b);
      if (aOnline != bOnline) return aOnline ? -1 : 1;
      return a.deviceName.compareTo(b.deviceName);
    });
    return copy;
  }

  bool _isConnected(PairedPeer peer) =>
      peer.state == PeerConnectionState.connected ||
      PeerConnectionManager.instance.getPeerState(peer.id) ==
          PeerConnectionState.connected;

  bool get _selfIsMaster =>
      _masterId != null && _masterId!.isNotEmpty && _masterId == _selfId;

  void _onLocalTap() {
    if (_selfId.isEmpty) return;
    if (widget.embedded) {
      widget.onLocalSelected?.call();
      return;
    }
    unawaited(_browseLocal());
  }

  Future<void> _browseLocal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageSpaceManageBrowser(
          usedBytes: _usedBytes,
        ),
      ),
    );
    if (mounted) unawaited(reload());
  }

  void _onPeerTap(PairedPeer peer) {
    if (widget.embedded) {
      widget.onPeerSelected?.call(peer);
      return;
    }
    _browsePeer(peer);
  }

  void _browsePeer(PairedPeer peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: peer.fingerprint,
          deviceName: peer.deviceName,
          peerId: peer.id,
          readOnly: true,
        ),
      ),
    );
  }

  void _onSnapshotsTap() {
    if (widget.embedded) {
      widget.onSnapshotsSelected?.call();
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const StorageSnapshotsScreen(),
      ),
    );
  }

  Future<void> _confirmSetMaster({
    required String deviceId,
    required String name,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_masterNode),
        content: Text(l10n.storage_setMasterExplainBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.storage_sharedSetMaster),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _setMaster(deviceId, name: name);
  }

  Future<void> _setMaster(String deviceId, {required String name}) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyFp = deviceId);
    try {
      await StoreService.instance.setMasterDeviceId(deviceId);
      unawaited(SyncEngine.instance.syncNow());
      await reload();
      if (mounted) {
        storageToast(context, l10n.storage_sharedMasterSet(name));
      }
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_nasConnectFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busyFp = null);
    }
  }

  Future<void> _showPeerActions(PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    final isMaster = _masterId == peer.fingerprint;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(l10n.storage_sharedBrowse),
              subtitle: Text(l10n.storage_sharedBrowseHint),
              onTap: () => Navigator.pop(ctx, 'browse'),
            ),
            if (!isMaster)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: Text(l10n.storage_sharedSetMaster),
                subtitle: Text(l10n.storage_setMasterExplainBody),
                onTap: () => Navigator.pop(ctx, 'master'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'browse':
        _onPeerTap(peer);
      case 'master':
        await _confirmSetMaster(
          deviceId: peer.fingerprint,
          name: peer.deviceName,
        );
    }
  }

  Future<void> _openPairing() async {
    final peer = await PeerPairingScreen.show(context);
    if (peer != null) await reload();
  }

  Widget _masterChip(AppLocalizations l10n, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l10n.storage_masterBadge,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _leadingIconBox(IconData icon) {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 20, color: AppColors.primary),
    );
  }

  Widget _hubRow({
    required Widget leading,
    required String title,
    required String subtitle,
    Color? subtitleColor,
    Widget? titleBadge,
    Widget? trailing,
    bool selected = false,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (titleBadge != null) ...[
                          const SizedBox(width: 6),
                          titleBadge,
                        ],
                      ],
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: subtitleColor ?? Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocalRow(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final used = _usedBytes;
    return _hubRow(
      leading: _leadingIconBox(
        widget.embedded
            ? Icons.computer_outlined
            : Icons.phone_android_outlined,
      ),
      title: l10n.storage_sharedThisDevice,
      subtitle: used != null
          ? fmtStorageBytes(used)
          : l10n.storage_sharedBrowseHint,
      titleBadge: _selfIsMaster ? _masterChip(l10n, colorScheme) : null,
      trailing:
          widget.embedded ? null : const Icon(Icons.chevron_right, size: 20),
      selected: widget.embedded && widget.localSelected,
      onTap: _selfId.isEmpty ? null : _onLocalTap,
      onLongPress: !_selfIsMaster && _selfId.isNotEmpty
          ? () => _confirmSetMaster(
                deviceId: _selfId,
                name: l10n.storage_sharedThisDevice,
              )
          : null,
    );
  }

  Widget _buildPeerRow(PairedPeer peer, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected = _isConnected(peer);
    final isMaster = _masterId == peer.fingerprint;
    final busy = _busyFp == peer.fingerprint;

    Widget? trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (!widget.embedded) {
      trailing = const Icon(Icons.chevron_right, size: 20);
    }

    return _hubRow(
      leading: Stack(
        children: [
          PeerDeviceIcon(peer: peer, size: _avatarSize, borderRadius: 8),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isConnected ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
      title: peer.deviceName,
      subtitle: peer.state.listStatusLabel(l10n),
      subtitleColor: isConnected ? Colors.green : Colors.grey,
      titleBadge: isMaster ? _masterChip(l10n, colorScheme) : null,
      trailing: trailing,
      selected: widget.embedded && widget.selectedPeerId == peer.id,
      onTap: busy ? null : () => _onPeerTap(peer),
      onLongPress: busy ? null : () => _showPeerActions(peer),
    );
  }

  Widget _buildSharedEmpty(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Row(
        children: [
          Icon(Icons.devices_other, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.storage_pairedEmpty,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          ),
          TextButton(
            onPressed: _openPairing,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              l10n.storage_nasOpenPairing,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotsTile(AppLocalizations l10n) {
    return _hubRow(
      leading: _leadingIconBox(Icons.backup_outlined),
      title: l10n.storage_entrySnapshots,
      subtitle: l10n.storage_entrySnapshotsSub,
      trailing:
          widget.embedded ? null : const Icon(Icons.chevron_right, size: 20),
      selected: widget.embedded && widget.snapshotsSelected,
      onTap: _onSnapshotsTap,
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildLocalRow(l10n),
          if (_peers.isEmpty)
            _buildSharedEmpty(l10n)
          else
            for (final peer in _peers) _buildPeerRow(peer, l10n),
          const Divider(height: 16, indent: 64),
          _buildSnapshotsTile(l10n),
          ...widget.footer,
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = _buildBody(l10n);
    if (!widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        elevation: 0,
      ),
      body: body,
    );
  }
}

/// 本机文件浏览（从 [StorageSpaceHub] 进入），保留「更多设置」菜单。
class StorageSpaceManageBrowser extends StatefulWidget {
  final int? usedBytes;

  const StorageSpaceManageBrowser({super.key, this.usedBytes});

  @override
  State<StorageSpaceManageBrowser> createState() =>
      _StorageSpaceManageBrowserState();
}

class _StorageSpaceManageBrowserState extends State<StorageSpaceManageBrowser> {
  void _openSettings(StorageSpaceSettingsSection section) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageSpaceSettingsScreen(initialSection: section),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StorageBrowserScreen(
      usedBytes: widget.usedBytes,
      extraActions: [
        PopupMenuButton<StorageSpaceSettingsSection>(
          tooltip: l10n.storage_moreSettings,
          icon: const Icon(Icons.more_horiz),
          position: PopupMenuPosition.under,
          onSelected: _openSettings,
          itemBuilder: (ctx) => _settingsMenuItems(l10n),
        ),
      ],
      extraMenuItems: (ctx) => _settingsMenuItems(l10n),
      onExtraMenuSelected: (value) {
        if (value is StorageSpaceSettingsSection) {
          _openSettings(value);
        }
      },
    );
  }

  List<PopupMenuEntry<StorageSpaceSettingsSection>> _settingsMenuItems(
    AppLocalizations l10n,
  ) {
    return [
      PopupMenuItem(
        value: StorageSpaceSettingsSection.usage,
        child: Text(l10n.storage_usageTitle),
      ),
      PopupMenuItem(
        value: StorageSpaceSettingsSection.bindings,
        child: Text(l10n.storage_bindingsSection),
      ),
      PopupMenuItem(
        value: StorageSpaceSettingsSection.recycle,
        child: Text(l10n.storage_recycleSection),
      ),
    ];
  }
}
