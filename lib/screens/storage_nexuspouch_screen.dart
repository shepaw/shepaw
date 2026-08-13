import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../storage/device_identity.dart';
import '../storage/nexuspouch_discovery_service.dart';
import '../storage/store_service.dart';
import '../storage/sync_engine.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';
import 'storage_snapshots_screen.dart';

/// 共享储物袋：配对设备互读 + 指定 master 备份 + LAN Nexuspouch 发现。
class StorageNexuspouchScreen extends StatefulWidget {
  const StorageNexuspouchScreen({super.key});

  @override
  State<StorageNexuspouchScreen> createState() =>
      _StorageNexuspouchScreenState();
}

class _StorageNexuspouchScreenState extends State<StorageNexuspouchScreen> {
  final _discovery = NexuspouchDiscoveryService.instance;
  StreamSubscription<List<DiscoveredNexuspouch>>? _sub;
  StreamSubscription<dynamic>? _peerEventsSub;
  StreamSubscription<void>? _peerListSub;
  StreamSubscription<SyncStatus>? _syncSub;
  List<DiscoveredNexuspouch> _peers = const [];
  List<PairedPeer> _paired = const [];
  String? _masterId;
  String _selfId = '';
  int _pendingCount = 0;
  int _pendingBytes = 0;
  bool _scanning = false;
  String? _busyFp;
  final _storage = PeerStorageService();

  @override
  void initState() {
    super.initState();
    _peers = _discovery.latest;
    _sub = _discovery.stream.listen((list) {
      if (mounted) setState(() => _peers = list);
    });
    _peerEventsSub = PeerConnectionManager.instance.events.listen((_) {
      unawaited(_loadPairedState());
    });
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      unawaited(_loadPairedState());
    });
    _syncSub = SyncEngine.instance.status.listen((s) {
      if (!mounted) return;
      setState(() {
        _pendingCount = s.pendingCount;
        _pendingBytes = s.pendingBytes;
      });
    });
    unawaited(_loadPairedState());
    unawaited(_scan());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _peerEventsSub?.cancel();
    _peerListSub?.cancel();
    _syncSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPairedState() async {
    final paired = await PeerConnectionManager.instance.getAllPeers();
    final master = await StoreService.instance.masterDeviceId();
    final self = await DeviceIdentity.deviceId();
    final pending = await SyncEngine.instance.pendingCount();
    final pendingBytes = await SyncEngine.instance.pendingBytes();
    if (!mounted) return;
    setState(() {
      _paired = paired;
      _masterId = master;
      _selfId = self;
      _pendingCount = pending;
      _pendingBytes = pendingBytes;
    });
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await _discovery.browse();
      await _loadPairedState();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  bool _isPaired(String fp) =>
      fp.isNotEmpty && _paired.any((p) => p.fingerprint == fp);

  /// 仅展示已配对且在局域网可见的节点；陌生节点不在 UI 中列出。
  List<DiscoveredNexuspouch> get _visibleDiscoveredPeers =>
      _peers.where((n) => _isPaired(n.fingerprint)).toList(growable: false);

  bool _isConnected(PairedPeer peer) =>
      peer.state == PeerConnectionState.connected ||
      PeerConnectionManager.instance.getPeerState(peer.id) ==
          PeerConnectionState.connected;

  Future<void> _setMaster(String deviceId, {String? name}) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyFp = deviceId);
    try {
      await StoreService.instance.setMasterDeviceId(deviceId);
      unawaited(SyncEngine.instance.syncNow());
      await _loadPairedState();
      if (mounted) {
        storageToast(
          context,
          l10n.storage_sharedMasterSet(name ?? deviceId),
        );
      }
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_nasConnectFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busyFp = null);
    }
  }

  Future<void> _connect(DiscoveredNexuspouch node) async {
    final l10n = AppLocalizations.of(context);
    if (node.fingerprint.isEmpty) {
      storageToast(context, l10n.storage_nasMissingFingerprint);
      return;
    }
    setState(() => _busyFp = node.fingerprint);
    try {
      final peer = await _storage.getPeerByFingerprint(node.fingerprint);
      if (peer == null) {
        if (!mounted) return;
        final goPair = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.storage_nasNotPairedTitle),
            content: Text(l10n.storage_nasNotPairedBody(node.name)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.storage_nasOpenPairing),
              ),
            ],
          ),
        );
        if (goPair == true && mounted) {
          final result = await PeerPairingScreen.show(context,
              initialTabIndex: PeerPairingScreen.scanTabIndex);
          if (result != null) await _loadPairedState();
        }
        return;
      }

      await _storage.updateLocalEndpoint(peer.id, node.endpoint);
      await PeerConnectionManager.instance.connectToPeer(peer);
      await StoreService.instance.setMasterDeviceId(node.fingerprint);
      unawaited(SyncEngine.instance.syncNow());
      await _loadPairedState();
      if (mounted) {
        storageToast(context, l10n.storage_nasConnected(node.name));
      }
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_nasConnectFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busyFp = null);
    }
  }

  Future<void> _openPairing() async {
    final peer = await PeerPairingScreen.show(context);
    if (peer != null) await _loadPairedState();
  }

  void _browseDevice({
    required String deviceId,
    required String name,
    String? peerId,
    bool readOnly = true,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: deviceId,
          deviceName: name,
          peerId: peerId,
          readOnly: readOnly,
        ),
      ),
    );
  }

  Widget _masterChip(AppLocalizations l10n, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l10n.storage_masterBadge,
        style: TextStyle(
          fontSize: 11,
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasPaired = _paired.isNotEmpty;
    final masterIsRemote =
        _masterId != null && _masterId!.isNotEmpty && _masterId != _selfId;
    final selfIsMaster = _masterId == _selfId;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_entryNas),
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.common_refresh,
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.storage_nasHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          if (masterIsRemote && _pendingCount > 0) ...[
            const SizedBox(height: 12),
            Material(
              color: scheme.secondaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text(l10n.storage_sharedSyncPending(
                  _pendingCount,
                  _fmtBytes(_pendingBytes),
                )),
                subtitle: Text(l10n.storage_pendingToMaster),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const StorageSnapshotsScreen(),
                    ),
                  );
                },
                trailing: IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: l10n.storage_sharedSyncNow,
                  onPressed: () async {
                    await SyncEngine.instance.syncNow();
                    await _loadPairedState();
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            l10n.storage_sharedDevicesSection,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          // 本机
          Card(
            child: ListTile(
              leading: Icon(
                Icons.phone_android_outlined,
                color: selfIsMaster ? scheme.primary : null,
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      l10n.storage_sharedThisDevice,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selfIsMaster) ...[
                    const SizedBox(width: 8),
                    _masterChip(l10n, scheme),
                  ],
                ],
              ),
              subtitle: Text(
                _selfId.length > 8
                    ? '${_selfId.substring(0, 8)}…'
                    : _selfId,
              ),
              trailing: const Icon(Icons.folder_open_outlined),
              onTap: _selfId.isEmpty
                  ? null
                  : () => _browseDevice(
                        deviceId: _selfId,
                        name: l10n.storage_sharedThisDevice,
                        readOnly: false,
                      ),
              onLongPress: selfIsMaster
                  ? null
                  : () => _setMaster(
                        _selfId,
                        name: l10n.storage_sharedThisDevice,
                      ),
            ),
          ),
          if (!hasPaired)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.storage_pairedEmpty,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            ..._paired.map((peer) {
              final isMaster = _masterId == peer.fingerprint;
              final connected = _isConnected(peer);
              final busy = _busyFp == peer.fingerprint;
              return Card(
                child: ListTile(
                  leading: Icon(
                    Icons.devices_outlined,
                    color: isMaster ? scheme.primary : null,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          peer.deviceName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isMaster) ...[
                        const SizedBox(width: 8),
                        _masterChip(l10n, scheme),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      peer.fingerprint.length > 8
                          ? '${peer.fingerprint.substring(0, 8)}…'
                          : peer.fingerprint,
                      connected
                          ? l10n.peerList_connected
                          : l10n.storage_nasPaired,
                    ].join(' · '),
                  ),
                  trailing: busy
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : PopupMenuButton<String>(
                          onSelected: (v) async {
                            switch (v) {
                              case 'browse':
                                _browseDevice(
                                  deviceId: peer.fingerprint,
                                  name: peer.deviceName,
                                  peerId: peer.id,
                                );
                              case 'master':
                                await _setMaster(
                                  peer.fingerprint,
                                  name: peer.deviceName,
                                );
                              case 'settings':
                                await PeerSettingsScreen.show(context, peer);
                                await _loadPairedState();
                            }
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(
                              value: 'browse',
                              child: Text(l10n.storage_sharedBrowse),
                            ),
                            if (!isMaster)
                              PopupMenuItem(
                                value: 'master',
                                child: Text(l10n.storage_sharedSetMaster),
                              ),
                            PopupMenuItem(
                              value: 'settings',
                              child: Text(l10n.peerSettings_title),
                            ),
                          ],
                        ),
                  onTap: () => _browseDevice(
                    deviceId: peer.fingerprint,
                    name: peer.deviceName,
                    peerId: peer.id,
                  ),
                ),
              );
            }),
          const SizedBox(height: 16),
          Text(
            l10n.storage_discoveredSection,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          if (_visibleDiscoveredPeers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  _scanning
                      ? l10n.storage_nasScanning
                      : l10n.storage_nasEmpty,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          else
            ..._visibleDiscoveredPeers.map((n) {
              final busy = _busyFp == n.fingerprint;
              final isMaster = _masterId == n.fingerprint;
              PairedPeer? localPeer;
              for (final p in _paired) {
                if (p.fingerprint == n.fingerprint) {
                  localPeer = p;
                  break;
                }
              }
              final connected =
                  localPeer != null ? _isConnected(localPeer) : false;
              return Card(
                child: ListTile(
                  leading: Icon(
                    Icons.storage,
                    color: isMaster ? scheme.primary : null,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(n.name, overflow: TextOverflow.ellipsis),
                      ),
                      if (isMaster) ...[
                        const SizedBox(width: 8),
                        _masterChip(l10n, scheme),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      l10n.storage_nasPaired,
                      if (n.fingerprint.isNotEmpty) n.shortFp,
                      n.endpoint,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: busy
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : connected
                          ? Text(
                              l10n.peerList_connected,
                              style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : FilledButton(
                              onPressed: () => _connect(n),
                              child: Text(l10n.storage_nasConnect),
                            ),
                ),
              );
            }),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _openPairing,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(
              hasPaired
                  ? l10n.storage_nasAddDevice
                  : l10n.storage_nasOpenPairing,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text(l10n.storage_agentsAdmin),
            subtitle: Text(l10n.storage_agentsAdminHint),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: _openAgentsAdmin,
          ),
        ],
      ),
    );
  }

  Future<void> _openAgentsAdmin() async {
    final l10n = AppLocalizations.of(context);
    String? adminUrl;
    if (_masterId != null) {
      for (final n in _peers) {
        if (n.fingerprint == _masterId) {
          adminUrl = 'http://${n.host}:${n.port}/admin';
          break;
        }
      }
    }
    adminUrl ??= _peers.isNotEmpty
        ? 'http://${_peers.first.host}:${_peers.first.port}/admin'
        : null;
    if (adminUrl == null) {
      for (final p in _paired) {
        final ep = p.preferredEndpoint;
        if (ep == null || ep.isEmpty) continue;
        final uri = Uri.tryParse(ep);
        if (uri != null && uri.host.isNotEmpty) {
          final port = uri.hasPort ? uri.port : 8787;
          adminUrl = 'http://${uri.host}:$port/admin';
          break;
        }
      }
    }
    if (adminUrl == null) {
      storageToast(context, l10n.storage_agentsAdminMissing);
      return;
    }
    final ok = await launchUrl(Uri.parse(adminUrl),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      storageToast(context, adminUrl);
    }
  }
}
