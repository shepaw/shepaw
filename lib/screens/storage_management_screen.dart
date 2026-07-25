import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/local_file_storage_service.dart';
import '../sync/peer_sync_service.dart';
import '../sync/sync_roles.dart';
import '../sync/sync_store.dart';

/// 存储空间管理页（docs/pc_primary_storage_plan.md §5，M1 只读）。
///
/// hub 与 console 打开同一页面、权限不同（§5.2）：
/// - hub：主存储卡片（库大小/水位）+ 各 console 的游标/落后/在线状态；
/// - console：顶部标注"由工作站 X 管理"，展示本机副本游标与用量；
///   hub 在线时经 stats 帧拉取实时水位（§8）。
class StorageManagementScreen extends StatefulWidget {
  const StorageManagementScreen({super.key});

  @override
  State<StorageManagementScreen> createState() =>
      _StorageManagementScreenState();
}

class _DeviceRow {
  _DeviceRow({required this.peer, required this.online, this.syncInfo});
  final PairedPeer peer;
  final bool online;
  final SyncDeviceInfo? syncInfo;
}

class _ViewModel {
  bool localIsHub = false;
  String myDeviceName = '';
  int dbBytes = 0;
  int attachmentBytes = 0;
  int seqWatermark = 0;
  List<_DeviceRow> devices = [];

  // console 侧
  String? hubDeviceName;
  bool hubOnline = false;
  SyncCursorState? cursor;
  Map<String, dynamic>? hubReport; // hub 在线时的实时统计
}

class _StorageManagementScreenState extends State<StorageManagementScreen> {
  late Future<_ViewModel> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ViewModel> _load() async {
    final vm = _ViewModel();
    final peers = await PeerStorageService().loadAllPeers();
    final store = SyncStore(await LocalDatabaseService().database);
    final manager = PeerConnectionManager.instance;

    vm.myDeviceName = await PeerPairingService.instance.getDeviceName();
    vm.dbBytes = await store.dbBytes();
    vm.attachmentBytes = await _dirBytes(
        await LocalFileStorageService().getStorageDirectory());

    final syncPeers = peers.where((p) => p.syncEnabled).toList();
    vm.localIsHub =
        syncPeers.any((p) => p.deviceRole == SyncDeviceRole.console.name);

    if (vm.localIsHub) {
      vm.seqWatermark = await store.currentSeq();
      final infos = {for (final d in await store.devices()) d.peerId: d};
      vm.devices = [
        for (final p in syncPeers)
          _DeviceRow(
            peer: p,
            online: manager.connectedPeerIds.contains(p.id),
            syncInfo: infos[p.id],
          ),
      ];
    } else {
      vm.cursor = await store.cursorState();
      final hubPeer = syncPeers
          .where((p) => p.deviceRole == SyncDeviceRole.hub.name)
          .firstOrNull;
      if (hubPeer != null) {
        vm.hubDeviceName = hubPeer.deviceName;
        vm.hubOnline = manager.connectedPeerIds.contains(hubPeer.id);
        vm.devices = [
          _DeviceRow(
            peer: hubPeer,
            online: vm.hubOnline,
          ),
        ];
        if (vm.hubOnline) {
          vm.hubReport = await PeerSyncService.instance.queryHubStats();
        }
      }
    }
    return vm;
  }

  Future<int> _dirBytes(Directory dir) async {
    var total = 0;
    try {
      await for (final f in dir.list(recursive: true)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _future = _load()),
          ),
        ],
      ),
      body: FutureBuilder<_ViewModel>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final vm = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildHubCard(context, l10n, vm),
              const SizedBox(height: 24),
              Text(
                l10n.storage_devicesTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (vm.devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      l10n.storage_noSyncDevices,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                ...vm.devices.map((d) => _buildDeviceTile(context, l10n, vm, d)),
            ],
          );
        },
      ),
    );
  }

  /// §5.1-1 主存储设备卡片。
  Widget _buildHubCard(
      BuildContext context, AppLocalizations l10n, _ViewModel vm) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = vm.localIsHub
        ? '${vm.myDeviceName}（${l10n.storage_thisDevice}）'
        : (vm.hubDeviceName ?? '—');
    final online = vm.localIsHub ? true : vm.hubOnline;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(l10n.storage_hubCardTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Icon(Icons.circle,
                    size: 10,
                    color: online ? Colors.green : colorScheme.outline),
              ],
            ),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(
              l10n.storage_hubImplFlutter,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant),
            ),
            if (!vm.localIsHub && vm.hubDeviceName != null) ...[
              const SizedBox(height: 4),
              Text(
                l10n.storage_managedBy(vm.hubDeviceName!),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant),
              ),
            ],
            const Divider(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _metric(l10n.storage_dbSize(_fmtBytes(vm.dbBytes))),
                _metric(l10n.storage_attachmentSize(
                    _fmtBytes(vm.attachmentBytes))),
                if (vm.localIsHub)
                  _metric(l10n.storage_seqWatermark(vm.seqWatermark)),
                if (!vm.localIsHub && vm.cursor != null)
                  _metric(l10n.storage_syncCursor(vm.cursor!.lastAppliedSeq)),
                if (!vm.localIsHub && vm.hubReport != null)
                  _metric(l10n.storage_seqWatermark(
                      vm.hubReport!['seq_watermark'] as int? ?? 0)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String text) => Text(text);

  /// §5.1-2 配对设备行（M1 只读：角色/平台/连接/游标/落后/最近同步）。
  Widget _buildDeviceTile(BuildContext context, AppLocalizations l10n,
      _ViewModel vm, _DeviceRow row) {
    final colorScheme = Theme.of(context).colorScheme;
    final peer = row.peer;
    final isHubPeer = peer.deviceRole == SyncDeviceRole.hub.name;
    final roleLabel = switch (peer.deviceRole) {
      'hub' => l10n.storage_roleHub,
      'console' => l10n.storage_roleConsole,
      _ => l10n.storage_roleNone,
    };

    final subtitle = <String>[];
    if (row.syncInfo != null) {
      final info = row.syncInfo!;
      subtitle.add(_stateLabel(l10n, info.state));
      subtitle.add(l10n.storage_syncCursor(info.lastAckSeq));
      final lag = vm.seqWatermark - info.lastAckSeq;
      if (lag > 0) subtitle.add(l10n.storage_lag(lag));
      if (info.updatedAtMs > 0) {
        subtitle
            .add(l10n.storage_lastSync(_fmtTime(info.updatedAtMs)));
      }
    } else if (!vm.localIsHub && vm.cursor != null) {
      subtitle.add(_stateLabel(l10n, vm.cursor!.state));
    }

    return Card(
      child: ListTile(
        leading: Icon(_platformIcon(peer.peerPlatform)),
        title: Row(
          children: [
            Flexible(child: Text(peer.deviceName)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isHubPeer
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(roleLabel,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
        subtitle: subtitle.isEmpty ? null : Text(subtitle.join(' · ')),
        trailing: Icon(Icons.circle,
            size: 10,
            color: row.online ? Colors.green : colorScheme.outline),
      ),
    );
  }

  String _stateLabel(AppLocalizations l10n, String state) => switch (state) {
        SyncCursorState.stateRoleNegotiated =>
          l10n.storage_state_role_negotiated,
        SyncCursorState.stateAdopting => l10n.storage_state_adopting,
        SyncCursorState.stateSnapshotSync => l10n.storage_state_snapshot_sync,
        SyncCursorState.stateActive => l10n.storage_state_active,
        _ => l10n.storage_state_unpaired,
      };

  IconData _platformIcon(String? platform) => switch (platform) {
        'macos' || 'windows' || 'linux' => Icons.computer,
        'ios' || 'android' => Icons.smartphone,
        _ => Icons.devices_other,
      };

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
