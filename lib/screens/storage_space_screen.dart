import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../service_locator.dart';
import '../services/password_service.dart';
import '../services/remote_agent_service.dart';
import '../services/she_service.dart';
import '../she_network/digest_service.dart';
import '../she_network/exchange_settings.dart';
import '../she_network/external_memory_store.dart';
import '../she_network/memory_exchange_service.dart';
import '../she_network/presence_service.dart';
import '../she_network/she_network_protocol.dart';
import '../storage/device_identity.dart';
import '../storage/import_auth_service.dart';
import '../storage/master_migration_service.dart';
import '../storage/mirror_reprotect_service.dart';
import '../storage/restore_service.dart';
import '../storage/scheduled_snapshot_service.dart';
import '../storage/snapshot_crypto.dart';
import '../storage/snapshot_import_service.dart';
import '../storage/snapshot_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'storage_import_scanner_screen.dart';

/// 存储空间页（docs/storage_space_plan.md §7）。
///
/// M1：本机快照（生成/校验/恢复/导出）。
/// M2：存储空间区块——master 展示、用量统计、回收站（还原/清空，
/// 清空仅 master 本机，docs/storage_protocol_spec.md §2.8）。
class StorageSpaceScreen extends StatefulWidget {
  const StorageSpaceScreen({super.key});

  @override
  State<StorageSpaceScreen> createState() => _StorageSpaceScreenState();
}

class _StorageSpaceScreenState extends State<StorageSpaceScreen> {
  late Future<List<SnapshotInfo>> _future;
  final Map<String, SnapshotVerifyStatus> _verifyCache = {};
  bool _busy = false;

  // M2 区块状态
  String _masterId = '';
  String _selfId = '';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _recycle = [];
  bool _recycleExpanded = false;

  // M3 区块状态
  ScheduledSnapshotStatus? _schedStatus;
  int _passwordChangedAtMs = 0;
  List<ImportGrant> _receivedGrants = [];
  List<Map<String, dynamic>> _pendingImports = [];
  final _oldDeviceController = TextEditingController();

  // M8 她的朋友圈
  ExchangeSettings _exchange =
      ExchangeSettings(enabled: false, kinds: {...DigestKind.all});
  List<PairedPeer> _ownerPeers = [];
  Map<String, int> _extCounts = {};
  String _localSheName = SheService.sheName;
  StreamSubscription<ImportRequest>? _importCreatedSub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _importCreatedSub = ImportRequestBus.instance.onCreated.listen((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _importCreatedSub?.cancel();
    _oldDeviceController.dispose();
    super.dispose();
  }

  Future<List<SnapshotInfo>> _load() async {
    final list = await SnapshotService.instance.listSnapshots();
    for (final s in list) {
      if (!_verifyCache.containsKey(s.id)) {
        _verifyCache[s.id] = await SnapshotService.instance.verifySnapshot(s);
      }
    }
    await _loadSpace();
    return list;
  }

  Future<void> _loadSpace() async {
    _selfId = await DeviceIdentity.deviceId();
    _masterId = await StoreService.instance.masterDeviceId();
    final stats = await StoreService.instance
        .call(StoreFrame(op: StoreOp.stats, payload: {}));
    if (stats != null && !stats.containsKey('_error')) {
      _stats = stats;
    }
    final recycle = await StoreService.instance
        .call(StoreFrame(op: StoreOp.recycleList, payload: {}));
    if (recycle != null && recycle['entries'] is List) {
      _recycle = (recycle['entries'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    }
    // M3：调度状态 + 改密时间 + 导入授权/请求
    _schedStatus = await ScheduledSnapshotService.instance.status();
    _passwordChangedAtMs =
        await ScheduledSnapshotService.instance.passwordChangedAtMs();
    final grants = await StoreService.instance.call(StoreFrame(
        op: StoreOp.importGrants, payload: {'role': 'received'}));
    if (grants != null && grants['grants'] is List) {
      _receivedGrants = (grants['grants'] as List)
          .map((e) => ImportGrant.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    final pending = await StoreService.instance
        .call(StoreFrame(op: StoreOp.importPending, payload: {}));
    if (pending != null && pending['requests'] is List) {
      _pendingImports = (pending['requests'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    }
    // M8：交换设置 + owner 同伴 + 外部记忆计数
    _exchange = await ExchangeSettings.load();
    final peers = await PeerStorageService().loadAllPeers();
    _ownerPeers =
        peers.where((p) => p.trustLevel == TrustLevel.owner).toList();
    _extCounts = await ExternalMemoryStore.instance.countsByDevice();
    _localSheName = await DigestService.instance.localSheName();
  }

  Future<void> _refresh() async {
    _verifyCache.clear();
    setState(() => _future = _load());
  }

  // ------------------------------------------------------------ 操作

  /// 密码输入对话框；返回密码或 null（取消）。
  Future<String?> _askPassword({String? title}) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title ?? l10n.storage_passwordTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.storage_passwordHint,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    return (result == null || result.isEmpty) ? null : result;
  }

  Future<void> _snapshotNow() async {
    final l10n = AppLocalizations.of(context);
    final password = await _askPassword();
    if (password == null) return;
    if (!await PasswordService().verifyPassword(password)) {
      _toast(l10n.storage_passwordWrong);
      return;
    }
    setState(() => _busy = true);
    try {
      await SnapshotService.instance.createSnapshot(password: password);
      _toast(l10n.storage_snapshotDone);
      await _refresh();
    } catch (e) {
      _toast(l10n.storage_snapshotFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(SnapshotInfo info) async {
    final l10n = AppLocalizations.of(context);
    // 全量替换语义强提示（§5.3）
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Theme.of(ctx).colorScheme.error, size: 36),
        title: Text(l10n.storage_restoreTitle),
        content: Text(l10n.storage_restoreWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.storage_restoreConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final password = await _askPassword();
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final preview =
          await RestoreService.instance.prepareRestore(info, password);
      final safetyHash = await SnapshotCrypto.cachedPasswordHash();
      await RestoreService.instance.executeRestore(preview, password,
          safetyPasswordHash: safetyHash);
      _toast(l10n.storage_restoreDone, duration: const Duration(seconds: 6));
    } on StateError catch (e) {
      _toast(e.message.contains('wrong password')
          ? l10n.storage_passwordWrong
          : l10n.storage_restoreFailed(e.message));
    } catch (e) {
      _toast(l10n.storage_restoreFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(SnapshotInfo info) async {
    final l10n = AppLocalizations.of(context);
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    setState(() => _busy = true);
    try {
      final out = await SnapshotService.instance.exportToDirectory(info, dir);
      if (out.missingAttachments.isEmpty) {
        _toast(
          out.packedAttachments > 0
              ? l10n.storage_exportDoneWithAttachments(
                  out.directory.path, out.packedAttachments)
              : l10n.storage_exportDone(out.directory.path),
          duration: const Duration(seconds: 5),
        );
      } else {
        _toast(
          l10n.storage_exportDonePartial(out.directory.path,
              out.packedAttachments, out.missingAttachments.length),
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      _toast(l10n.storage_snapshotFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(seconds: 3),
    ));
  }

  // ------------------------------------------------------------ 回收站操作

  Future<void> _recycleRestore(Map<String, dynamic> entry) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final res = await StoreService.instance.call(StoreFrame(
          op: StoreOp.recycleRestore,
          payload: {'recycle_path': entry['recycle_path']}));
      if (res != null && res.containsKey('_error')) {
        _toast(l10n.storage_recycleRestoreFailed('${res['_error']}'));
        return;
      }
      await _refresh();
      _toast(l10n.storage_recycleRestored);
    } catch (e) {
      _toast(l10n.storage_recycleRestoreFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recyclePurgeAll() async {
    final l10n = AppLocalizations.of(context);
    if (_masterId != _selfId || _selfId.isEmpty) {
      _toast(l10n.storage_recyclePurgeMasterOnly);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_forever,
            color: Theme.of(ctx).colorScheme.error, size: 36),
        content: Text(l10n.storage_recyclePurgeConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final res = await StoreService.instance
          .call(StoreFrame(op: StoreOp.recycleEmpty, payload: {}));
      if (res != null && res.containsKey('_error')) {
        _toast(l10n.storage_recyclePurgeFailed('${res['_error']}'));
        return;
      }
      final purged = res?['purged_bytes'] as int? ?? 0;
      _toast(l10n.storage_recyclePurged(_fmtBytes(purged)));
      await _refresh();
    } catch (e) {
      _toast(l10n.storage_recyclePurgeFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          FutureBuilder<List<SnapshotInfo>>(
            future: _future,
            builder: (context, snap) {
              final list = snap.data ?? const <SnapshotInfo>[];
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildSpaceSection(l10n),
                  const SizedBox(height: 20),
                  _buildSheCircleSection(l10n),
                  const SizedBox(height: 20),
                  _buildHeader(l10n),
                  const SizedBox(height: 20),
                  _buildImportCard(l10n),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text(l10n.storage_snapshotSection,
                          style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _busy ? null : _snapshotNow,
                        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                        label: Text(l10n.storage_snapshotNow),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (snap.connectionState != ConnectionState.done)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(l10n.storage_noSnapshots,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                      ),
                    )
                  else
                    ...list.map((s) => _buildSnapshotTile(l10n, s)),
                ],
              );
            },
          ),
          if (_busy)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ M6 master 迁移

  /// 旧 master ≠ 本机且当前不可达时，升主存在历史 blob 缺口风险（方案 §6.5）。
  Future<bool> _oldMasterGapRisk() async {
    final masterId = await StoreService.instance.masterDeviceId();
    if (masterId == _selfId) return false;
    return !await StoreService.instance.masterOnline();
  }

  Future<bool> _confirmMigrate(String deviceLabel) async {
    final l10n = AppLocalizations.of(context);
    final gapRisk = await _oldMasterGapRisk();
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.storage_migrateConfirm(deviceLabel)),
                if (gapRisk) ...[
                  const SizedBox(height: 12),
                  Text(l10n.storage_migrateGapWarning),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(l10n.common_confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _toastMigrateDone(AppLocalizations l10n, MigrationResult result) {
    if (!result.oldMasterReachable) {
      _toast(l10n.storage_migrateDoneGap(result.epoch));
      return;
    }
    if (result.hashGate.ran && !result.hashGate.ok) {
      _toast(l10n.storage_migrateDoneHashMismatch(
          result.epoch, result.hashGate.mismatches.length));
      return;
    }
    _toast(l10n.storage_migrateDone(result.epoch));
  }

  Future<void> _becomeMaster() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _confirmMigrate(l10n.storage_thisDevice);
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final result = await MasterMigrationService.instance.promoteSelf();
      await _refresh();
      _toastMigrateDone(l10n, result);
    } catch (e) {
      _toast(l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickMigrateTarget() async {
    final l10n = AppLocalizations.of(context);
    final peers = await PeerStorageService().loadAllPeers();
    final owners = peers
        .where((p) => p.trustLevel == 'owner' && p.fingerprint != _selfId)
        .toList();
    if (!mounted) return;
    final choices = <(String, String)>[
      (_selfId, l10n.storage_thisDevice),
      for (final p in owners)
        (p.fingerprint, '${p.deviceName} (${p.fingerprint.substring(0, 8)}…)'),
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.storage_migratePick),
        children: [
          for (final (id, label) in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(id),
              child: Text(label),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final label = choices.firstWhere((c) => c.$1 == picked).$2;
    final confirmed = await _confirmMigrate(label);
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final result =
          await MasterMigrationService.instance.requestPromote(picked);
      await _refresh();
      if (result != null) {
        _toastMigrateDone(l10n, result);
      }
    } catch (e) {
      _toast(l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprotectNow() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final id = await MirrorReprotectService.instance.runIfMaster();
      if (id == null) {
        _toast(l10n.storage_reprotectSkipped);
      } else {
        _toast(l10n.storage_reprotectDone(id));
        await _refresh();
      }
    } catch (e) {
      _toast(l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ M2 存储空间区块

  Widget _buildSpaceSection(AppLocalizations l10n) {
    final isMaster = _masterId == _selfId && _selfId.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.storage_spaceSection,
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_outlined,
                        color: Theme.of(context).colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(l10n.storage_masterNode,
                        style: Theme.of(context).textTheme.bodyMedium),
                    const Spacer(),
                    Text(
                      isMaster
                          ? '${_masterId.substring(0, 8)}…（${l10n.storage_thisDevice}）'
                          : _masterId,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (!isMaster)
                      FilledButton.tonal(
                        onPressed: _busy ? null : _becomeMaster,
                        child: Text(l10n.storage_becomeMaster),
                      ),
                    OutlinedButton(
                      onPressed: _busy ? null : _pickMigrateTarget,
                      child: Text(l10n.storage_migrateMaster),
                    ),
                    if (isMaster)
                      OutlinedButton(
                        onPressed: _busy ? null : _reprotectNow,
                        child: Text(l10n.storage_reprotectNow),
                      ),
                  ],
                ),
                if (_stats != null) ...[
                  const Divider(height: 20),
                  Text(l10n.storage_usageTitle,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  _buildUsageChips(l10n),
                  _buildSyncStatus(l10n),
                  _buildVolumeWarning(l10n),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildRecycleCard(l10n),
      ],
    );
  }

  Widget _buildSheCircleSection(AppLocalizations l10n) {
    final presence = PresenceService.instance.known;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(l10n.storage_sheCircleSection,
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _renameLocalShe,
                  child: Text(l10n.storage_renameShe),
                ),
              ],
            ),
            Text(
              '${l10n.storage_sheCircleHint}\n${SheService.resolveDisplayName(_localSheName, l10n.she_name)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.storage_exchangeEnabled),
              value: _exchange.enabled,
              onChanged: _busy
                  ? null
                  : (v) async {
                      final next = _exchange.copyWith(enabled: v);
                      await next.save();
                      setState(() => _exchange = next);
                    },
            ),
            Text(l10n.storage_exchangeKinds,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final kind in DigestKind.all)
                  FilterChip(
                    label: Text(_kindLabel(l10n, kind)),
                    selected: _exchange.kinds.contains(kind),
                    onSelected: _busy
                        ? null
                        : (sel) async {
                            final kinds = Set<String>.of(_exchange.kinds);
                            if (sel) {
                              kinds.add(kind);
                            } else {
                              kinds.remove(kind);
                            }
                            if (kinds.isEmpty) return;
                            final next = _exchange.copyWith(kinds: kinds);
                            await next.save();
                            setState(() => _exchange = next);
                          },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _busy || !_exchange.enabled ? null : _exchangeNow,
                child: Text(l10n.storage_exchangeNow),
              ),
            ),
            const Divider(height: 24),
            if (_ownerPeers.isEmpty)
              Text(l10n.storage_noOwnerPeers,
                  style: Theme.of(context).textTheme.bodySmall)
            else
              ..._ownerPeers.map((peer) {
                final p = presence[peer.fingerprint];
                final count = _extCounts[peer.fingerprint] ?? 0;
                final title = p?.sheName.isNotEmpty == true
                    ? p!.sheName
                    : peer.deviceName;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(title),
                  subtitle: Text(
                    '${l10n.storage_peerTrust(peer.trustLevel)} · '
                    '${l10n.storage_externalMemories(count)}'
                    '${p == null ? ' · ${l10n.storage_presenceOffline}' : ''}',
                  ),
                  dense: true,
                );
              }),
          ],
        ),
      ),
    );
  }

  String _kindLabel(AppLocalizations l10n, String kind) {
    switch (kind) {
      case DigestKind.preference:
        return l10n.storage_kindPreference;
      case DigestKind.ongoing:
        return l10n.storage_kindOngoing;
      case DigestKind.fact:
        return l10n.storage_kindFact;
      default:
        return kind;
    }
  }

  Future<void> _exchangeNow() async {
    setState(() => _busy = true);
    try {
      final ok = await MemoryExchangeService.instance.offerToAllOwners();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _toast(ok ? l10n.storage_exchangeDone : l10n.storage_exchangeSkipped);
      await _loadSpace();
      setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameLocalShe() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(
      text: SheService.resolveDisplayName(_localSheName, l10n.she_name),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_renameShe),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.storage_renameSheHint,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: l10n.she_name),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel)),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final normalized = SheService.normalizeStoredName(name, l10n.she_name);
    try {
      final agentService = getIt<RemoteAgentService>();
      final agent = await agentService.getAgentById(SheService.sheId);
      if (agent != null) {
        await agentService.updateAgent(agent.copyWith(name: normalized));
      }
      await PresenceService.instance.broadcastNow(
          localizedSheName: l10n.she_name);
      setState(() => _localSheName = normalized);
      _toast(l10n.storage_sheNameSaved);
    } catch (e) {
      _toast('$e');
    }
  }

  Widget _buildUsageChips(AppLocalizations l10n) {
    final devices = (_stats!['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    final mine = (devices[_selfId] as Map?)?.cast<String, dynamic>() ?? {};
    final staging = _stats!['staging_bytes'] as int? ?? 0;
    final recycle = _stats!['recycle_bytes'] as int? ?? 0;
    final volumeTotal = _stats!['volume_total_bytes'] as int?;
    final volumeFree = _stats!['volume_free_bytes'] as int?;
    final volumeWarn = _stats!['volume_warn'] == true;
    final chips = <Widget>[
      for (final space in ['artifacts', 'files', 'attachments', 'backups'])
        Chip(
          label: Text('$space ${_fmtBytes(mine[space] as int? ?? 0)}'),
          visualDensity: VisualDensity.compact,
        ),
      if (staging > 0)
        Chip(
          label: Text('staging ${_fmtBytes(staging)}'),
          visualDensity: VisualDensity.compact,
        ),
      if (recycle > 0)
        Chip(
          label: Text('.recycle ${_fmtBytes(recycle)}'),
          visualDensity: VisualDensity.compact,
        ),
      if (volumeTotal != null && volumeFree != null)
        Chip(
          label: Text(l10n.storage_volumeFree(
              _fmtBytes(volumeFree), _fmtBytes(volumeTotal))),
          visualDensity: VisualDensity.compact,
          backgroundColor: volumeWarn
              ? Theme.of(context).colorScheme.errorContainer
              : null,
        ),
    ];
    return Wrap(spacing: 8, runSpacing: 4, children: chips);
  }

  /// 方案 §7：卷用量 ≥80% 告警。
  Widget _buildVolumeWarning(AppLocalizations l10n) {
    if (_stats!['volume_warn'] != true) return const SizedBox.shrink();
    final ratio = (_stats!['volume_used_ratio'] as num?)?.toDouble() ?? 0;
    final pct = (ratio * 100).round();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.storage_rounded,
              size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l10n.storage_volumeWarning(pct),
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  /// M4：未同步占用与游标水位（§6.4 磁盘压力展示 + 超阈值告警）。
  Widget _buildSyncStatus(AppLocalizations l10n) {
    final unsyncedCount = _stats!['unsynced_count'] as int?;
    final unsyncedBytes = _stats!['unsynced_bytes'] as int?;
    final changeSeq = _stats!['change_seq'] as int?;
    final ackSeq = _stats!['ack_seq'] as int?;
    if (unsyncedCount == null) return const SizedBox.shrink();

    const warnBytes = 200 * 1024 * 1024; // 200MB 阈值
    final warn = (unsyncedBytes ?? 0) > warnBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(
              l10n.storage_unsynced(
                  unsyncedCount, _fmtBytes(unsyncedBytes ?? 0)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unsyncedCount > 0
                        ? Theme.of(context).colorScheme.tertiary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (changeSeq != null && ackSeq != null)
              Text(
                l10n.storage_syncCursor(ackSeq, changeSeq),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        if (warn)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.storage_unsyncedWarning,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRecycleCard(AppLocalizations l10n) {
    final isMaster = _masterId == _selfId && _selfId.isNotEmpty;
    const pageSize = 20;
    final visible = _recycleExpanded || _recycle.length <= pageSize
        ? _recycle
        : _recycle.take(pageSize).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(l10n.storage_recycleSection,
                    style: Theme.of(context).textTheme.bodyMedium),
                const Spacer(),
                if (isMaster && _recycle.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _recyclePurgeAll,
                    child: Text(l10n.storage_recyclePurgeAll),
                  ),
              ],
            ),
            if (_recycle.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.storage_recycleEmptyHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            else ...[
              ...visible.map((e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined,
                        size: 18),
                    title: Text('${e['space']}/${e['origin_path']}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${_fmtBytes(e['size'] as int? ?? 0)} · ${l10n.storage_deletedAt(_fmtRecycleDate(e['recycle_path'] as String))}'),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _recycleRestore(e),
                      child: Text(l10n.storage_recycleRestore),
                    ),
                  )),
              if (_recycle.length > pageSize)
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _recycleExpanded = !_recycleExpanded),
                    child: Text(_recycleExpanded
                        ? l10n.storage_recycleShowLess
                        : l10n.storage_recycleShowMore(_recycle.length)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtRecycleDate(String recyclePath) {
    // .recycle/<yyyy-MM-dd>/...
    final parts = recyclePath.split('/');
    return parts.length > 1 ? parts[1] : '';
  }

  // ------------------------------------------------------------ M3 换机导入

  /// 服务侧选择：旧设备在线则直连（路径 A），否则走 master（路径 B）。
  Future<String> _serverFor(String oldDeviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    final old = peers.where((p) => p.fingerprint == oldDeviceId).firstOrNull;
    if (old != null &&
        PeerConnectionManager.instance.connectedPeerIds.contains(old.id)) {
      return oldDeviceId;
    }
    return _masterId;
  }

  Future<void> _sendImportRequest() async {
    final l10n = AppLocalizations.of(context);
    final oldId = _oldDeviceController.text.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(oldId) || oldId == _selfId) {
      _toast(l10n.storage_oldDeviceId);
      return;
    }
    setState(() => _busy = true);
    try {
      final server = await _serverFor(oldId);
      final res = await StoreService.instance.callPeer(
          server, StoreFrame(op: StoreOp.importRequest, payload: {
        'old_device': oldId,
      }));
      if (res != null && res['request_id'] != null) {
        _toast(l10n.storage_importSent);
      } else {
        _toast(l10n.storage_importFailed('${res?['_error']}'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 扫码/粘贴旧设备 peer QR → 必要时先配对 → 填 ID 并发导入请求（§5.4 路径 A）。
  Future<void> _scanAndImport() async {
    final l10n = AppLocalizations.of(context);
    final info = await StorageImportScannerScreen.show(context);
    if (info == null || !mounted) return;
    _oldDeviceController.text = info.fingerprint;
    try {
      final existing =
          await PeerStorageService().getPeerByFingerprint(info.fingerprint);
      if (existing == null) {
        setState(() => _busy = true);
        _toast(l10n.storage_importPairing);
        try {
          await PeerPairingService.instance.requestPairing(info);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
      if (!mounted) return;
      await _sendImportRequest();
    } catch (e) {
      _toast(l10n.storage_importFailed('$e'));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showMyPairingQr() async {
    await PeerPairingScreen.show(context);
  }

  Future<void> _approveImport(Map<String, dynamic> req, bool approve) async {
    setState(() => _busy = true);
    try {
      await StoreService.instance.call(StoreFrame(
          op: approve ? StoreOp.importGrant : StoreOp.importReject,
          payload: {'request_id': req['request_id']}));
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 浏览旧设备快照 → 选择 → 密码 → 下载 → 恢复（保留本机身份）。
  Future<void> _browseAndImport(ImportGrant grant) async {
    final l10n = AppLocalizations.of(context);
    final server = await _serverFor(grant.oldDevice);
    List<String> snapshots;
    try {
      snapshots = await SnapshotImportService.instance.listRemoteSnapshots(
        serverDeviceId: server,
        oldDeviceId: grant.oldDevice,
        grantId: grant.grantId,
      );
    } catch (e) {
      _toast(l10n.storage_importFailed('$e'));
      return;
    }
    if (!mounted) return;
    if (snapshots.isEmpty) {
      _toast(l10n.storage_noRemoteSnapshots);
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.storage_importPickSnapshot),
        children: [
          for (final id in snapshots.take(20))
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(id),
              child: Text(id),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    final password = await _askPassword();
    if (password == null) return;

    setState(() => _busy = true);
    try {
      _toast(l10n.storage_importDownloading);
      final info = await SnapshotImportService.instance.downloadSnapshot(
        serverDeviceId: server,
        oldDeviceId: grant.oldDevice,
        snapshotId: picked,
        grantId: grant.grantId,
      );
      final preview =
          await RestoreService.instance.prepareRestore(info, password);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded,
              color: Theme.of(ctx).colorScheme.error, size: 36),
          content: Text(l10n.storage_importDone),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.common_cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.storage_importRestore),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      // 换机导入：保留本机 device_id（§5.4）；安全快照用当前主密码缓存
      final safetyHash = await SnapshotCrypto.cachedPasswordHash();
      await RestoreService.instance.executeRestore(preview, password,
          restoreIdentity: false, safetyPasswordHash: safetyHash);
      _toast(l10n.storage_restoreDone, duration: const Duration(seconds: 6));
    } on SnapshotDecryptException {
      _toast(l10n.storage_passwordWrong);
    } catch (e) {
      _toast(l10n.storage_importFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ M3 换机导入卡片

  Widget _buildImportCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.phonelink_ring_outlined,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.storage_importSection,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _showMyPairingQr,
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: Text(l10n.storage_importShowQr),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l10n.storage_importRequestHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _oldDeviceController,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: l10n.storage_oldDeviceId,
                    ),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _busy ? null : _scanAndImport,
                  tooltip: l10n.storage_importScan,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _busy ? null : _sendImportRequest,
                  child: Text(l10n.storage_importSend),
                ),
              ],
            ),

            // 待审批（本机为旧设备/master 时）
            if (_pendingImports.isNotEmpty) ...[
              const Divider(height: 24),
              Text(l10n.storage_importPending,
                  style: Theme.of(context).textTheme.bodySmall),
              ..._pendingImports.map((req) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.hourglass_top, size: 18),
                    title: Text(
                        l10n.storage_importFrom(
                            '${req['new_device']}'.substring(0, 8)),
                        style: Theme.of(context).textTheme.bodySmall),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed:
                              _busy ? null : () => _approveImport(req, true),
                          child: Text(l10n.storage_importApprove),
                        ),
                        TextButton(
                          onPressed:
                              _busy ? null : () => _approveImport(req, false),
                          child: Text(l10n.storage_importReject),
                        ),
                      ],
                    ),
                  )),
            ],

            // 我获得的授权
            if (_receivedGrants.isNotEmpty) ...[
              const Divider(height: 24),
              Text(l10n.storage_importMyGrants,
                  style: Theme.of(context).textTheme.bodySmall),
              ..._receivedGrants.map((g) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.key, size: 18),
                    title: Text(
                        l10n.storage_importFrom(
                            g.oldDevice.substring(0, 8)),
                        style: Theme.of(context).textTheme.bodySmall),
                    subtitle: Text(
                        l10n.storage_importExpires(_fmtTime(g.expiresAtMs)),
                        style: Theme.of(context).textTheme.labelSmall),
                    trailing: FilledButton.tonal(
                      onPressed: _busy ? null : () => _browseAndImport(g),
                      child: Text(l10n.storage_importBrowse),
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildHeader(AppLocalizations l10n) {
    final status = _schedStatus;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.backup_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.storage_snapshotDesc,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (status != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.storage_autoSnapshot,
                            style: Theme.of(context).textTheme.bodyMedium),
                        Text(
                          !status.enabled
                              ? l10n.storage_autoSnapshotOff
                              : !status.keyCached
                                  ? l10n.storage_noKeyHint
                                  : status.lastSuccessMs > 0
                                      ? l10n.storage_lastSuccess(_fmtTime(
                                          status.lastSuccessMs))
                                      : l10n.storage_noSnapshots,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: status.enabled,
                    onChanged: (v) async {
                      await ScheduledSnapshotService.instance.setEnabled(v);
                      await _refresh();
                    },
                  ),
                ],
              ),
              if (status.needsAttention)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l10n.storage_snapshotWarning,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotTile(AppLocalizations l10n, SnapshotInfo info) {
    final status = _verifyCache[info.id];
    final (label, color) = switch (status) {
      SnapshotVerifyStatus.ok => (l10n.storage_verifyOk, Colors.green),
      SnapshotVerifyStatus.fileTampered => (
          l10n.storage_verifyFileTampered,
          Theme.of(context).colorScheme.error
        ),
      SnapshotVerifyStatus.manifestTampered => (
          l10n.storage_verifyManifestTampered,
          Theme.of(context).colorScheme.error
        ),
      SnapshotVerifyStatus.unreadable => (
          l10n.storage_verifyUnreadable,
          Theme.of(context).colorScheme.error
        ),
      null => (l10n.storage_verifyUnknown, Theme.of(context).colorScheme.outline),
    };
    final t = info.createdAt;
    final timeLabel =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    // 改密前的快照：需旧密码恢复（§5.2 密码变更策略）
    final needsOldPassword = _passwordChangedAtMs > 0 &&
        info.manifest.createdAtMs < _passwordChangedAtMs;

    return Card(
      child: ListTile(
        leading: const Icon(Icons.save_as_outlined),
        title: Row(
          children: [
            Flexible(child: Text(timeLabel)),
            if (needsOldPassword) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color:
                      Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(l10n.storage_needsOldPassword,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
            ],
          ],
        ),
        subtitle: Text(
          '${_fmtBytes(info.totalBytes)} · schema v${info.manifest.schemaVersion} · $label',
          style: TextStyle(color: color),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _busy ? null : () => _export(info),
              child: Text(l10n.storage_export),
            ),
            TextButton(
              onPressed:
                  _busy || status != SnapshotVerifyStatus.ok
                      ? null
                      : () => _restore(info),
              child: Text(l10n.storage_restore),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
