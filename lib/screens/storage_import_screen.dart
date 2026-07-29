import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../storage/device_identity.dart';
import '../storage/import_auth_service.dart';
import '../storage/restore_service.dart';
import '../storage/snapshot_crypto.dart';
import '../storage/snapshot_import_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'storage_import_scanner_screen.dart';
import 'storage_shared.dart';

/// 换机导入子页（储物袋重构 §子页）：向旧设备发起导入请求、
/// 审批他端请求、凭授权浏览/下载/恢复快照。业务逻辑与原 M3 区块一致。
class StorageImportScreen extends StatefulWidget {
  const StorageImportScreen({super.key});

  @override
  State<StorageImportScreen> createState() => _StorageImportScreenState();
}

class _StorageImportScreenState extends State<StorageImportScreen> {
  bool _busy = false;

  String _masterId = '';
  String _selfId = '';
  List<ImportGrant> _receivedGrants = [];
  List<Map<String, dynamic>> _pendingImports = [];
  final _oldDeviceController = TextEditingController();

  StreamSubscription<ImportRequest>? _importCreatedSub;
  StreamSubscription<ImportGrant>? _importGrantSub;

  @override
  void initState() {
    super.initState();
    _load();
    _importCreatedSub = ImportRequestBus.instance.onCreated.listen((_) {
      if (mounted) unawaited(_load());
    });
    _importGrantSub = ImportGrantBus.instance.onReceived.listen((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _importCreatedSub?.cancel();
    _importGrantSub?.cancel();
    _oldDeviceController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _selfId = await DeviceIdentity.deviceId();
    _masterId = await StoreService.instance.masterDeviceId();
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
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 操作

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
      storageToast(context, l10n.storage_oldDeviceId);
      return;
    }
    setState(() => _busy = true);
    try {
      final server = await _serverFor(oldId);
      final res = await StoreService.instance.callPeer(
          server, StoreFrame(op: StoreOp.importRequest, payload: {
        'old_device': oldId,
      }));
      if (!mounted) return;
      if (res != null && res['request_id'] != null) {
        storageToast(context, l10n.storage_importSent);
      } else {
        storageToast(context, l10n.storage_importFailed('${res?['_error']}'));
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
        storageToast(context, l10n.storage_importPairing);
        try {
          await PeerPairingService.instance.requestPairing(info);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
      if (!mounted) return;
      await _sendImportRequest();
    } catch (e) {
      storageToast(context, l10n.storage_importFailed('$e'));
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
      await _load();
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
      storageToast(context, l10n.storage_importFailed('$e'));
      return;
    }
    if (!mounted) return;
    if (snapshots.isEmpty) {
      storageToast(context, l10n.storage_noRemoteSnapshots);
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

    final password = await askStoragePassword(context);
    if (password == null) return;

    setState(() => _busy = true);
    try {
      storageToast(context, l10n.storage_importDownloading);
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
      if (mounted) {
        storageToast(context, l10n.storage_restoreDone,
            duration: const Duration(seconds: 6));
      }
    } on SnapshotDecryptException {
      if (mounted) storageToast(context, l10n.storage_passwordWrong);
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_importFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.storage_importSection)),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.phonelink_ring_outlined,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(l10n.storage_importSection,
                                style:
                                    Theme.of(context).textTheme.titleSmall),
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
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
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
                              style:
                                  const TextStyle(fontFamily: 'monospace'),
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
                    ],
                  ),
                ),
              ),
              if (_pendingImports.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(l10n.storage_importPending,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final req in _pendingImports)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.hourglass_top, size: 18),
                          title: Text(
                              l10n.storage_importFrom(
                                  '${req['new_device']}'.substring(0, 8)),
                              style: Theme.of(context).textTheme.bodySmall),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _approveImport(req, true),
                                child: Text(l10n.storage_importApprove),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _approveImport(req, false),
                                child: Text(l10n.storage_importReject),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_receivedGrants.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(l10n.storage_importMyGrants,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final g in _receivedGrants)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.key, size: 18),
                          title: Text(
                              l10n.storage_importFrom(
                                  g.oldDevice.substring(0, 8)),
                              style: Theme.of(context).textTheme.bodySmall),
                          subtitle: Text(
                              l10n.storage_importExpires(_fmtTime(g.expiresAtMs)),
                              style: Theme.of(context).textTheme.labelSmall),
                          trailing: FilledButton.tonal(
                            onPressed:
                                _busy ? null : () => _browseAndImport(g),
                            child: Text(l10n.storage_importBrowse),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
