import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/screens/peer_pairing_screen.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../screens/storage_browser_screen.dart';
import '../../screens/storage_nexuspouch_screen.dart';
import '../../screens/storage_shared.dart';
import '../../screens/storage_space_settings_screen.dart';
import '../../peer/widgets/peer_device_icon.dart';
import '../../storage/device_identity.dart';
import '../../storage/store_service.dart';
import '../../storage/sync_engine.dart';
import '../../theme/app_theme.dart';

enum _StorageHubSection { local, shared }

/// 移动端储物袋空间：本机 + 配对共享设备（通讯录式折叠列表）。
class StorageSpaceHub extends StatefulWidget {
  final int? localUsedBytes;

  const StorageSpaceHub({super.key, this.localUsedBytes});

  @override
  State<StorageSpaceHub> createState() => _StorageSpaceHubState();
}

class _StorageSpaceHubState extends State<StorageSpaceHub> {
  static const double _rowPadH = 12;
  static const double _chevronSize = 20;
  static const double _chevronGap = 4;
  static const double _avatarSize = 36;
  static const double _childIndent = _rowPadH + _chevronSize + _chevronGap;

  final Set<_StorageHubSection> _expanded = {_StorageHubSection.local};
  List<PairedPeer> _peers = const [];
  String? _masterId;
  String _selfId = '';
  bool _loading = true;
  String? _busyFp;
  StreamSubscription<dynamic>? _peerEventsSub;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _peerEventsSub = PeerConnectionManager.instance.events.listen((_) {
      unawaited(_reload());
    });
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    _peerEventsSub?.cancel();
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await PeerConnectionManager.instance.start();
      final peers = await PeerConnectionManager.instance.getAllPeers();
      final master = await StoreService.instance.masterDeviceId();
      final self = await DeviceIdentity.deviceId();
      if (!mounted) return;
      setState(() {
        _peers = _sortedPeers(peers);
        _masterId = master;
        _selfId = self;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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

  void _toggleSection(_StorageHubSection section) {
    setState(() {
      if (_expanded.contains(section)) {
        _expanded.remove(section);
      } else {
        _expanded.add(section);
      }
    });
  }

  Future<void> _browseLocal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageSpaceManageBrowser(
          usedBytes: widget.localUsedBytes,
        ),
      ),
    );
    if (mounted) unawaited(_reload());
  }

  void _browsePeer(PairedPeer peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: peer.fingerprint,
          deviceName: peer.deviceName,
          readOnly: true,
        ),
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
      await _reload();
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
        _browsePeer(peer);
      case 'master':
        await _confirmSetMaster(
          deviceId: peer.fingerprint,
          name: peer.deviceName,
        );
    }
  }

  Future<void> _openPairing() async {
    final peer = await PeerPairingScreen.show(context);
    if (peer != null) await _reload();
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

  Widget _buildSectionHeader({
    required _StorageHubSection section,
    required String title,
    required int count,
    required IconData icon,
    required Color iconColor,
    bool showMasterBadge = false,
  }) {
    final l10n = AppLocalizations.of(context);
    final expanded = _expanded.contains(section);
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => _toggleSection(section),
      onLongPress: section == _StorageHubSection.local && !_selfIsMaster
          ? () => _confirmSetMaster(
                deviceId: _selfId,
                name: l10n.storage_sharedThisDevice,
              )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.chevron_right,
                size: _chevronSize,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: _chevronGap),
            Container(
              width: _avatarSize,
              height: _avatarSize,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (showMasterBadge) ...[
                    const SizedBox(width: 6),
                    _masterChip(l10n, colorScheme),
                  ],
                ],
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalChild(AppLocalizations l10n) {
    final used = widget.localUsedBytes;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: _childIndent, right: 16),
      leading: Container(
        width: _avatarSize,
        height: _avatarSize,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.folder_open_outlined, color: AppColors.primary, size: 20),
      ),
      title: Text(
        l10n.storage_browseLocalSpace,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        used != null ? fmtStorageBytes(used) : l10n.storage_sharedBrowseHint,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: _browseLocal,
    );
  }

  Widget _buildPeerRow(PairedPeer peer, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected = _isConnected(peer);
    final isMaster = _masterId == peer.fingerprint;
    final busy = _busyFp == peer.fingerprint;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : () => _browsePeer(peer),
        onLongPress: busy ? null : () => _showPeerActions(peer),
        child: Padding(
          padding: const EdgeInsets.only(left: _childIndent, right: 16, top: 6, bottom: 6),
          child: Row(
            children: [
              Stack(
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
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            peer.deviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (isMaster) ...[
                          const SizedBox(width: 6),
                          _masterChip(l10n, colorScheme),
                        ],
                      ],
                    ),
                    Text(
                      peer.state.listStatusLabel(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSharedEmpty(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_childIndent, 8, 16, 12),
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
            child: Text(l10n.storage_nasOpenPairing, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildSectionHeader(
            section: _StorageHubSection.local,
            title: l10n.storage_sharedThisDevice,
            count: 1,
            icon: Icons.phone_android_outlined,
            iconColor: AppColors.primary,
            showMasterBadge: _selfIsMaster,
          ),
          if (_expanded.contains(_StorageHubSection.local)) _buildLocalChild(l10n),
          _buildSectionHeader(
            section: _StorageHubSection.shared,
            title: l10n.storage_sharedDevicesSection,
            count: _peers.length,
            icon: Icons.devices_outlined,
            iconColor: const Color(0xFF576B95),
          ),
          if (_expanded.contains(_StorageHubSection.shared)) ...[
            if (_peers.isEmpty)
              _buildSharedEmpty(l10n)
            else
              for (final peer in _peers) _buildPeerRow(peer, l10n),
          ],
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: Text(l10n.storage_entryNas),
            subtitle: Text(l10n.storage_nasEntryHint),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const StorageNexuspouchScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
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
