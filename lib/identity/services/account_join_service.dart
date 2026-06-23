import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../peer/models/paired_peer.dart';
import '../../peer/services/peer_connection.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_pairing_service.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/biometric_service.dart';
import '../../services/logger_service.dart';
import '../../services/noise_identity.dart';
import '../models/account_join_request.dart';
import '../crypto/ed25519_identity.dart';
import '../models/account_join_result.dart';
import '../models/device_role.dart';
import '../models/identity_export_bundle.dart';
import 'account_identity_service.dart';
import 'account_session_service.dart';
import 'device_trust_service.dart';
import 'identity_export_service.dart';
import 'local_account_registry.dart';
import 'sync_client_service.dart';
import 'user_identity_service.dart';

/// 经 P2P 配对 + Noise 加密通道下发账号密钥，加入已有账号。
class AccountJoinService {
  AccountJoinService._();
  static final AccountJoinService instance = AccountJoinService._();

  static const _tag = 'AccountJoin';
  static const _joinTimeout = Duration(minutes: 2);
  static const _maxPendingJoinRequests = 20;
  static const _maxPendingJoinPerPeer = 3;

  final _log = LoggerService();
  final _biometric = BiometricService();
  final _uuid = const Uuid();

  StreamSubscription<PeerControlEvent>? _sub;
  bool _running = false;

  final _pendingController = StreamController<AccountJoinPendingRequest>.broadcast();
  Stream<AccountJoinPendingRequest> get pendingRequests => _pendingController.stream;

  final _joinWaiters = <String, Completer<Map<String, dynamic>?>>{};
  final _pendingById = <String, AccountJoinPendingRequest>{};
  Timer? _pendingExpiryTimer;

  void start() {
    if (_running) return;
    _running = true;
    _sub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _pendingExpiryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_pruneExpiredPending());
    });
    _log.info('AccountJoinService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _pendingExpiryTimer?.cancel();
    _pendingExpiryTimer = null;
    _sub?.cancel();
    _sub = null;
  }

  /// 新设备：配对完成后请求加入 Primary 账号。
  ///
  /// 若本机已有相同账号，跳过密钥导入，仅登记 Primary 并同步。
  Future<AccountJoinResult> joinViaPeer({
    required PairedPeer peer,
    DeviceRole preferredRole = DeviceRole.app,
    void Function(AccountJoinProgress progress)? onProgress,
  }) async {
    onProgress?.call(AccountJoinProgress.waitingApproval);
    await _waitUntilConnected(peer.id);

    final pairing = PeerPairingService.instance;
    await pairing.ensureDeviceInfo();
    final transport = await NoiseIdentity.loadOrCreate();
    final requestId = _uuid.v4();

    final completer = Completer<Map<String, dynamic>?>();
    _joinWaiters[requestId] = completer;

    final sent = await PeerConnectionManager.instance.sendControl(peer.id, {
      'type': 'account_join_req',
      'request_id': requestId,
      'device_id': await pairing.getDeviceId(),
      'device_name': await pairing.getDeviceName(),
      'transport_fingerprint': transport.fingerprintHex,
      'transport_public_key': base64.encode(transport.publicKey),
      'preferred_role': preferredRole.wireValue,
    });
    if (!sent) {
      _joinWaiters.remove(requestId);
      throw StateError('Failed to send join request (peer not connected)');
    }

    final resp = await completer.future.timeout(
      _joinTimeout,
      onTimeout: () {
        _joinWaiters.remove(requestId);
        return null;
      },
    );
    if (resp == null) throw StateError('Join request timed out');
    if (resp['ok'] != true) {
      throw StateError(resp['error']?.toString() ?? 'Join rejected');
    }

    onProgress?.call(AccountJoinProgress.connectingAccount);

    final bundle = IdentityExportBundle(
      userRecord: resp['user_record'] as String,
      petRecord: resp['pet_record'] as String,
      exportedAtMs: resp['exported_at_ms'] as int,
      signatureBase64: resp['sig'] as String,
    );

    if (!await IdentityExportService.instance.verifyBundle(bundle)) {
      throw StateError('Invalid identity export bundle');
    }

    final remoteUser = Ed25519Identity.parseRecord(bundle.userRecord);
    final accountId = remoteUser.fingerprintHex;
    final alreadyLocal = await UserIdentityService.instance.existsForAccount(accountId);

    if (alreadyLocal) {
      await LocalAccountRegistry.instance.setActiveAccountId(accountId);
      AccountIdentityService.instance.resetInMemory();
      AccountSessionService.instance.resetSyncState();
      await AccountSessionService.instance.switchToAccount(accountId);
      await AccountIdentityService.instance.ensureInitialized();
      _log.info('Reconnected to existing account $accountId', tag: _tag);
    } else {
      await IdentityExportService.instance.importBundle(
        bundle,
        preferredRole: preferredRole,
      );
    }

    await DeviceTrustService.instance.registerPrimaryFromPeer(peer);
    await AccountSessionService.instance.activate();

    unawaited(_sendTrustAcceptToPeer(peer.id));

    onProgress?.call(AccountJoinProgress.syncing);
    try {
      await SyncClientService.instance.syncWithPeer(peer.id);
      _log.info(
        alreadyLocal
            ? 'Re-synced account via P2P from ${peer.deviceName}'
            : 'Joined account via P2P from ${peer.deviceName}',
        tag: _tag,
      );
      return AccountJoinResult(reconnected: alreadyLocal, syncSucceeded: true);
    } catch (e) {
      _log.warning('Initial sync after join failed: $e', tag: _tag);
      return AccountJoinResult(
        reconnected: alreadyLocal,
        syncSucceeded: false,
        syncError: e.toString(),
      );
    }
  }

  Future<void> _sendTrustAcceptToPeer(String peerId) async {
    try {
      final payload = await DeviceTrustService.instance.buildTrustAcceptPayload();
      await PeerConnectionManager.instance.sendControl(peerId, payload);
    } catch (e) {
      _log.warning('trust_accept after join failed: $e', tag: _tag);
    }
  }

  /// Primary：批准加入请求（生物识别 + 下发账号密钥）。
  Future<void> approveJoin(String requestId) async {
    final pending = _pendingById.remove(requestId);
    if (pending == null) throw StateError('Join request not found or expired');

    final peer = await PeerStorageService().getPeerById(pending.peerId);
    if (peer?.deviceId == null || peer!.deviceId != pending.deviceId) {
      throw StateError('Join request device_id does not match paired peer');
    }

    await AccountIdentityService.instance.ensureInitialized();
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) {
      throw StateError('Only primary storage device can approve account join');
    }

    if (await _biometric.isDeviceSupported()) {
      final ok = await _biometric.authenticate(
        reason: 'Approve device joining your account',
      );
      if (!ok) throw StateError('Biometric verification cancelled');
    }

    final bundle = await IdentityExportService.instance.buildSignedBundle(
      requireBiometric: false,
    );

    await PeerConnectionManager.instance.sendControl(pending.peerId, {
      'type': 'account_join_resp',
      'request_id': requestId,
      'ok': true,
      'user_record': bundle.userRecord,
      'pet_record': bundle.petRecord,
      'exported_at_ms': bundle.exportedAtMs,
      'sig': bundle.signatureBase64,
    });

    final pub = base64.decode(pending.transportPublicKeyBase64);
    await DeviceTrustService.instance.registerTrustedRemoteDevice(
      deviceId: pending.deviceId,
      deviceName: pending.deviceName,
      transportPublicKey: Uint8List.fromList(pub),
      fingerprint: pending.transportFingerprint,
      role: pending.preferredRole,
    );

    _log.info('Approved account join for ${pending.deviceName}', tag: _tag);
  }

  /// Primary：拒绝加入请求。
  Future<void> rejectJoin(String requestId, {String? reason}) async {
    final pending = _pendingById.remove(requestId);
    if (pending == null) return;

    await PeerConnectionManager.instance.sendControl(pending.peerId, {
      'type': 'account_join_resp',
      'request_id': requestId,
      'ok': false,
      'error': reason ?? 'rejected',
    });
  }

  void _onControl(PeerControlEvent event) {
    switch (event.type) {
      case 'account_join_req':
        unawaited(_handleJoinReq(event.peerId, event.data));
        break;
      case 'account_join_resp':
        _completeJoinWaiter(event.data);
        break;
    }
  }

  Future<void> _handleJoinReq(String peerId, Map<String, dynamic> data) async {
    try {
      if (!await UserIdentityService.instance.exists()) return;

      await AccountIdentityService.instance.ensureInitialized();
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.primary) {
        final requestId = data['request_id'] as String? ?? '';
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'account_join_resp',
          'request_id': requestId,
          'ok': false,
          'error': 'primary_required',
        });
        return;
      }

      final requestId = data['request_id'] as String? ?? '';
      if (requestId.isEmpty) return;

      await _pruneExpiredPending();
      if (_pendingById.length >= _maxPendingJoinRequests) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'account_join_resp',
          'request_id': requestId,
          'ok': false,
          'error': 'too_many_pending',
        });
        return;
      }
      if (_pendingById.values.where((p) => p.peerId == peerId).length >=
          _maxPendingJoinPerPeer) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'account_join_resp',
          'request_id': requestId,
          'ok': false,
          'error': 'rate_limited',
        });
        return;
      }

      final peer = await PeerStorageService().getPeerById(peerId);
      final reqDeviceId = data['device_id'] as String? ?? '';
      if (peer?.deviceId != null &&
          reqDeviceId.isNotEmpty &&
          peer!.deviceId != reqDeviceId) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'account_join_resp',
          'request_id': requestId,
          'ok': false,
          'error': 'device_id_mismatch',
        });
        return;
      }

      final pending = AccountJoinPendingRequest(
        requestId: requestId,
        peerId: peerId,
        deviceId: peer?.deviceId ?? reqDeviceId,
        deviceName: data['device_name'] as String? ?? 'Device',
        transportFingerprint: data['transport_fingerprint'] as String? ?? '',
        transportPublicKeyBase64: data['transport_public_key'] as String? ?? '',
        preferredRole: DeviceRole.fromWire(data['preferred_role'] as String?),
        requestedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

      _pendingById[requestId] = pending;
      _pendingController.add(pending);
      _log.info('Account join request from ${pending.deviceName}', tag: _tag);
      unawaited(_pruneExpiredPending());
    } catch (e) {
      _log.warning('handle account_join_req failed: $e', tag: _tag);
    }
  }

  void _completeJoinWaiter(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _joinWaiters.remove(id)?.complete(data);
  }

  Future<void> _waitUntilConnected(String peerId) async {
    if (PeerConnectionManager.instance.getPeerState(peerId) ==
        PeerConnectionState.connected) {
      return;
    }

    final peer = await PeerStorageService().getPeerById(peerId);
    if (peer == null) throw StateError('Peer not found');

    PeerConnectionManager.instance.connectToPeer(peer);

    if (PeerConnectionManager.instance.getPeerState(peerId) ==
        PeerConnectionState.connected) {
      return;
    }

    final completer = Completer<void>();
    late StreamSubscription<PeerConnectionEvent> sub;
    sub = PeerConnectionManager.instance.events.listen((event) {
      if (event.peerId == peerId &&
          event.type == PeerConnectionEventType.connected) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });

    await completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => throw StateError('P2P connection timeout'),
    );
  }

  Future<void> _pruneExpiredPending() async {
    if (_pendingById.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = _pendingById.entries
        .where((e) => now - e.value.requestedAtMs > _joinTimeout.inMilliseconds)
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      await rejectJoin(id, reason: 'expired');
    }
  }
}
