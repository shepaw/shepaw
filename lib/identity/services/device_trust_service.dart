import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../services/biometric_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/noise_identity.dart';
import '../../peer/services/peer_pairing_service.dart';
import '../crypto/ed25519_identity.dart';
import '../models/device_role.dart';
import '../models/device_trust_invite.dart';
import '../models/owned_device_record.dart';
import 'account_identity_service.dart';

/// 签发与验证「添加自有设备」Trust 邀请。
class DeviceTrustService {
  DeviceTrustService._();
  static final DeviceTrustService instance = DeviceTrustService._();

  static const _tag = 'DeviceTrust';
  static const _inviteTtlMs = 10 * 60 * 1000;

  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _biometric = BiometricService();
  final _random = Random.secure();

  Future<DeviceTrustInvite> createInvite() async {
    await AccountIdentityService.instance.ensureInitialized();

    if (await _biometric.isDeviceSupported()) {
      final ok = await _biometric.authenticate(
        reason: 'Verify identity to add a trusted device',
      );
      if (!ok) throw StateError('Biometric verification cancelled');
    }

    final user = await AccountIdentityService.instance.userIdentity();
    final pet = await AccountIdentityService.instance.spiritPetIdentity();
    final local = await AccountIdentityService.instance.localDevice();
    if (local == null) throw StateError('Local device not registered');

    final nonce = _randomHex(16);
    final expires = DateTime.now().millisecondsSinceEpoch + _inviteTtlMs;

    final unsigned = DeviceTrustInvite(
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      issuerDeviceId: local.deviceId,
      issuerDeviceName: local.deviceName,
      transportFingerprint: local.fingerprint,
      nonce: nonce,
      expiresAtMs: expires,
      userPublicKeyBase64: user.publicKeyBase64,
      signatureBase64: '',
    );
    final sig = base64.encode(await user.signUtf8(unsigned.signedPayload));

    final invite = DeviceTrustInvite(
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      issuerDeviceId: local.deviceId,
      issuerDeviceName: local.deviceName,
      transportFingerprint: local.fingerprint,
      nonce: nonce,
      expiresAtMs: expires,
      userPublicKeyBase64: user.publicKeyBase64,
      signatureBase64: sig,
    );

    _log.info('Created device trust invite for ${local.deviceName}', tag: _tag);
    return invite;
  }

  Future<bool> verifyInvite(DeviceTrustInvite invite) async {
    if (invite.isExpired) return false;
    final pub = base64.decode(invite.userPublicKeyBase64);
    if (pub.length != 32) return false;
    final sig = base64.decode(invite.signatureBase64);
    return Ed25519Identity.verifyUtf8(
      message: invite.signedPayload,
      signature: Uint8List.fromList(sig),
      publicKey: Uint8List.fromList(pub),
    );
  }

  /// 新设备接受邀请：登记签发设备为自有设备（需已导入同一 User/Pet 身份）。
  Future<void> acceptInvite(DeviceTrustInvite invite) async {
    if (!await verifyInvite(invite)) {
      throw StateError('Invalid or expired trust invite');
    }

    await AccountIdentityService.instance.ensureInitialized();
    final user = await AccountIdentityService.instance.userIdentity();
    final pet = await AccountIdentityService.instance.spiritPetIdentity();

    if (invite.userId != user.fingerprintHex || invite.petId != pet.fingerprintHex) {
      throw StateError(
        'Account mismatch: import the same account on this device before accepting the invite',
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _db.getOwnedDeviceByDeviceId(invite.issuerDeviceId);
    if (existing != null) {
      await _db.upsertOwnedDevice(existing.copyWith(
        deviceName: invite.issuerDeviceName,
        lastSeenAt: now,
      ));
      return;
    }

    final record = OwnedDeviceRecord(
      id: invite.issuerDeviceId,
      deviceId: invite.issuerDeviceId,
      deviceName: invite.issuerDeviceName,
      role: DeviceRole.primary, // 签发方通常是 Primary；后续 role_announce 修正
      transportPublicKey: Uint8List(32),
      fingerprint: invite.transportFingerprint,
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      isLocal: false,
      trustedAt: now,
      lastSeenAt: now,
    );
    await _db.upsertOwnedDevice(record);
    _log.info('Accepted trust invite from ${invite.issuerDeviceName}', tag: _tag);
  }

  /// 签发方登记接受方（P2P trust_accept 或配对完成后调用）。
  Future<void> registerTrustedRemoteDevice({
    required String deviceId,
    required String deviceName,
    required Uint8List transportPublicKey,
    required String fingerprint,
    DeviceRole role = DeviceRole.app,
  }) async {
    await AccountIdentityService.instance.ensureInitialized();
    final user = await AccountIdentityService.instance.userIdentity();
    final pet = await AccountIdentityService.instance.spiritPetIdentity();
    final now = DateTime.now().millisecondsSinceEpoch;

    final record = OwnedDeviceRecord(
      id: deviceId,
      deviceId: deviceId,
      deviceName: deviceName,
      role: role,
      transportPublicKey: transportPublicKey,
      fingerprint: fingerprint,
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      isLocal: false,
      trustedAt: now,
      lastSeenAt: now,
    );
    await _db.upsertOwnedDevice(record);
  }

  /// 本机作为新设备，向 Primary 发送 trust_accept（含 Noise 传输指纹）。
  Future<Map<String, dynamic>> buildTrustAcceptPayload() async {
    await AccountIdentityService.instance.ensureInitialized();
    final user = await AccountIdentityService.instance.userIdentity();
    final pet = await AccountIdentityService.instance.spiritPetIdentity();
    final pairing = PeerPairingService.instance;
    await pairing.ensureDeviceInfo();
    final transport = await NoiseIdentity.loadOrCreate();
    final local = await AccountIdentityService.instance.localDevice();

    return {
      'type': 'sync_trust_accept',
      'user_id': user.fingerprintHex,
      'pet_id': pet.fingerprintHex,
      'device_id': local?.deviceId ?? await pairing.getDeviceId(),
      'device_name': await pairing.getDeviceName(),
      'transport_fingerprint': transport.fingerprintHex,
      'transport_public_key': base64.encode(transport.publicKey),
    };
  }

  String _randomHex(int byteLen) {
    final sb = StringBuffer();
    for (var i = 0; i < byteLen; i++) {
      sb.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
