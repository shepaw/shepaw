import 'dart:convert';
import 'dart:typed_data';

import '../../services/biometric_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../crypto/ed25519_identity.dart';
import '../models/device_role.dart';
import '../models/identity_export_bundle.dart';
import 'account_identity_service.dart';
import 'local_account_registry.dart';
import 'spirit_pet_identity_service.dart';
import 'user_identity_service.dart';

/// 导出 / 导入 User + SpiritPet 身份包（新设备加入同一账号）。
class IdentityExportService {
  IdentityExportService._();
  static final IdentityExportService instance = IdentityExportService._();

  static const _tag = 'IdentityExport';
  final _log = LoggerService();
  final _biometric = BiometricService();

  Future<IdentityExportBundle> exportBundle() async {
    return buildSignedBundle(requireBiometric: true);
  }

  /// 构建已签名的账号密钥包（供 P2P 加入或离线导出）。
  Future<IdentityExportBundle> buildSignedBundle({bool requireBiometric = true}) async {
    await AccountIdentityService.instance.ensureInitialized();

    if (requireBiometric && await _biometric.isDeviceSupported()) {
      final ok = await _biometric.authenticate(
        reason: 'Verify identity to export account keys',
      );
      if (!ok) throw StateError('Biometric verification cancelled');
    }

    final user = await AccountIdentityService.instance.userIdentity();
    final pet = await AccountIdentityService.instance.spiritPetIdentity();
    final exportedAt = DateTime.now().millisecondsSinceEpoch;

    final bundle = IdentityExportBundle(
      userRecord: user.encodeRecord(),
      petRecord: pet.encodeRecord(),
      bondMap: null,
      exportedAtMs: exportedAt,
      signatureBase64: '',
    );

    final sig = await user.signUtf8(bundle.signedPayload);
    return IdentityExportBundle(
      userRecord: bundle.userRecord,
      petRecord: bundle.petRecord,
      bondMap: bundle.bondMap,
      exportedAtMs: exportedAt,
      signatureBase64: base64.encode(sig),
    );
  }

  Future<bool> verifyBundle(IdentityExportBundle bundle) async {
    try {
      final user = Ed25519Identity.parseRecord(bundle.userRecord);
      final sig = base64.decode(bundle.signatureBase64);
      return Ed25519Identity.verifyUtf8(
        message: bundle.signedPayload,
        signature: Uint8List.fromList(sig),
        publicKey: user.publicKey,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> importBundle(
    IdentityExportBundle bundle, {
    DeviceRole? preferredRole,
  }) async {
    if (!await verifyBundle(bundle)) {
      throw StateError('Invalid identity export bundle signature');
    }

    final user = Ed25519Identity.parseRecord(bundle.userRecord);
    final accountId = user.fingerprintHex;

    await LocalAccountRegistry.instance.registerAccount(accountId);
    await LocalAccountRegistry.instance.setActiveAccountId(accountId);
    await LocalDatabaseService().switchAccount(accountId);

    await Ed25519Identity.importRecord(UserIdentityService.storageKeyFor(accountId), bundle.userRecord);
    await Ed25519Identity.importRecord(SpiritPetIdentityService.storageKeyFor(accountId), bundle.petRecord);

    await AccountIdentityService.instance.resetAfterIdentityImport(
      preferredRole: preferredRole,
    );
    _log.info('Identity bundle imported successfully', tag: _tag);
  }
}
