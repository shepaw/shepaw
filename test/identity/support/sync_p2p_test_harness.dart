import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
import 'package:shepaw/identity/services/sync_protocol_service.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// 三角色 device / peer 固定 ID（单进程 mock 网络）。
class SyncP2pTestIds {
  static const appDevice = 'device-app';
  static const appPeer = 'peer-app';
  static const primaryDevice = 'device-primary';
  static const primaryPeer = 'peer-primary';
  static const backupDevice = 'device-backup';
  static const backupPeer = 'peer-backup';
  static const userId = 'test-user';
  static const petId = 'test-pet';
}

/// 记录 mock 网络发出的 control 帧。
class CapturedSyncControl {
  final String toPeerId;
  final Map<String, dynamic> payload;

  const CapturedSyncControl(this.toPeerId, this.payload);

  String? get type => payload['type'] as String?;
}

/// In-memory P2P 路由：拦截 [PeerConnectionManager.sendControl] 并按需模拟 Primary。
class SyncP2pTestRouter {
  final Map<String, PeerConnectionState> peerStates = {};
  final sent = <CapturedSyncControl>[];

  /// 收到发往 Primary 的 sync_commit 时调用；返回 null 表示不自动回包。
  Future<Map<String, dynamic>?> Function(
    String fromPeerId,
    Map<String, dynamic> commit,
  )? onPrimaryCommit;

  void setConnected(String peerId, {bool connected = true}) {
    peerStates[peerId] =
        connected ? PeerConnectionState.connected : PeerConnectionState.disconnected;
  }

  void install() {
    for (final id in [
      SyncP2pTestIds.appPeer,
      SyncP2pTestIds.primaryPeer,
      SyncP2pTestIds.backupPeer,
    ]) {
      setConnected(id, connected: true);
    }
    PeerConnectionManager.debugSendControlOverride = _send;
    PeerConnectionManager.debugGetPeerStateOverride =
        (peerId) => peerStates[peerId] ?? PeerConnectionState.disconnected;
  }

  void uninstall() {
    PeerConnectionManager.debugSendControlOverride = null;
    PeerConnectionManager.debugGetPeerStateOverride = null;
    peerStates.clear();
    sent.clear();
    onPrimaryCommit = null;
  }

  Future<bool> _send(String toPeerId, Map<String, dynamic> json) async {
    if (peerStates[toPeerId] != PeerConnectionState.connected) {
      return false;
    }
    sent.add(CapturedSyncControl(toPeerId, json));

    if (toPeerId == SyncP2pTestIds.primaryPeer &&
        json['type'] == 'sync_commit' &&
        onPrimaryCommit != null) {
      final fromPeer = _lastFromPeerId ?? SyncP2pTestIds.backupPeer;
      final resp = await onPrimaryCommit!(fromPeer, json);
      if (resp != null) {
        // 异步投递，模拟真实 P2P：sendControl 返回后 response 才到达 waiter。
        scheduleMicrotask(() {
          SyncProtocolService.instance.dispatchControlForTest(
            SyncP2pTestIds.primaryPeer,
            resp,
          );
        });
      }
    }
    return true;
  }

  String? _lastFromPeerId;

  void noteSender(String peerId) => _lastFromPeerId = peerId;

  CapturedSyncControl? lastSentTo(String peerId) {
    for (var i = sent.length - 1; i >= 0; i--) {
      if (sent[i].toPeerId == peerId) return sent[i];
    }
    return null;
  }

  List<CapturedSyncControl> sentTo(String peerId) =>
      sent.where((m) => m.toPeerId == peerId).toList();
}

/// 单节点 Sync 协议 P2P mock 测试脚手架。
class SyncP2pTestHarness {
  SyncP2pTestHarness._();

  final router = SyncP2pTestRouter();
  final db = LocalDatabaseService();
  final _uuid = const Uuid();
  late String accountId;

  static Future<SyncP2pTestHarness> create({
    required DeviceRole localRole,
    String localDeviceId = SyncP2pTestIds.backupDevice,
    String localPeerId = SyncP2pTestIds.backupPeer,
  }) async {
    final harness = SyncP2pTestHarness._();
    harness.accountId = 'p2p-test-${DateTime.now().microsecondsSinceEpoch}';
    await harness.db.close();
    await harness.db.switchAccount(harness.accountId);
    await harness.db.database;

    PeerStorageService().resetTablesReadyForTests();
    await PeerStorageService().ensureTables();

    await harness._seedOwnedGraph(
      localRole: localRole,
      localDeviceId: localDeviceId,
    );
    await harness._seedPeers();
    await AccountIdentityService.instance.activateAccountScopeForTests(harness.accountId);

    harness.router.install();
    SyncProtocolService.instance.stop();
    SyncProtocolService.instance.start();
    return harness;
  }

  Future<void> dispose() async {
    SyncProtocolService.instance.stop();
    router.uninstall();
    AccountIdentityService.instance.resetIdentityStateForTests();
    await db.close();
  }

  Future<void> _seedOwnedGraph({
    required DeviceRole localRole,
    required String localDeviceId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = Uint8List.fromList(List.filled(32, 7));

    await db.upsertIdentityUser(
      id: SyncP2pTestIds.userId,
      displayName: 'Test',
      publicKey: key,
      createdAt: now,
    );
    await db.upsertSpiritPet(
      id: SyncP2pTestIds.petId,
      userId: SyncP2pTestIds.userId,
      name: 'She',
      publicKey: key,
      agentId: 'agent-test',
      createdAt: now,
    );

    Future<void> addDevice({
      required String recordId,
      required String deviceId,
      required DeviceRole role,
      required bool isLocal,
    }) async {
      await db.upsertOwnedDevice(
        OwnedDeviceRecord(
          id: recordId,
          deviceId: deviceId,
          deviceName: deviceId,
          role: role,
          transportPublicKey: key,
          fingerprint: 'fp-$deviceId',
          userId: SyncP2pTestIds.userId,
          petId: SyncP2pTestIds.petId,
          isLocal: isLocal,
          trustedAt: now,
          lastSeenAt: now,
        ),
      );
    }

    await addDevice(
      recordId: 'rec-local',
      deviceId: localDeviceId,
      role: localRole,
      isLocal: true,
    );

    if (localRole != DeviceRole.primary) {
      await addDevice(
        recordId: 'rec-primary',
        deviceId: SyncP2pTestIds.primaryDevice,
        role: DeviceRole.primary,
        isLocal: false,
      );
    }

    if (localDeviceId != SyncP2pTestIds.appDevice) {
      await addDevice(
        recordId: 'rec-app',
        deviceId: SyncP2pTestIds.appDevice,
        role: DeviceRole.app,
        isLocal: false,
      );
    }
  }

  Future<void> _seedPeers() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = Uint8List.fromList(List.filled(32, 9));
    for (final entry in [
      (SyncP2pTestIds.appPeer, SyncP2pTestIds.appDevice),
      (SyncP2pTestIds.primaryPeer, SyncP2pTestIds.primaryDevice),
      (SyncP2pTestIds.backupPeer, SyncP2pTestIds.backupDevice),
    ]) {
      await PeerStorageService().savePeer(
        PairedPeer(
          id: entry.$1,
          deviceName: entry.$2,
          deviceId: entry.$2,
          publicKey: key,
          fingerprint: 'fp-${entry.$2}',
          pairedAt: now,
        ),
      );
    }
  }

  Map<String, dynamic> messageCommitPayload({
    String messageId = 'msg-p2p-1',
    String originDeviceId = SyncP2pTestIds.appDevice,
    int wallTimeMs = 5000,
    String content = 'hello from app',
  }) {
    final iso = DateTime.fromMillisecondsSinceEpoch(wallTimeMs).toIso8601String();
    final event = SyncEvent.messageEvent(
      messageRow: {
        'id': messageId,
        'channel_id': 'ch-p2p',
        'sender_id': originDeviceId,
        'sender_name': 'App User',
        'content': content,
        'created_at': iso,
        'updated_at': iso,
      },
      originDeviceId: originDeviceId,
    );
    return event.toJson();
  }

  Future<Map<String, dynamic>?> commitFromApp({
    String messageId = 'msg-p2p-1',
    String requestId = 'req-app-1',
  }) async {
    router.noteSender(SyncP2pTestIds.appPeer);
    final eventJson = messageCommitPayload(messageId: messageId);
    await SyncProtocolService.instance.dispatchControlForTest(
      SyncP2pTestIds.appPeer,
      {
        'type': 'sync_commit',
        'request_id': requestId,
        'event': eventJson,
      },
    );
    return router.lastSentTo(SyncP2pTestIds.appPeer)?.payload;
  }

  String newRequestId() => _uuid.v4();
}
