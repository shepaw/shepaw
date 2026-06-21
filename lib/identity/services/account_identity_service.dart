import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:uuid/uuid.dart';

import '../../peer/services/peer_pairing_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/noise_identity.dart';
import '../crypto/ed25519_identity.dart';
import '../models/device_role.dart';
import '../models/owned_device_record.dart';
import 'account_session_service.dart';
import 'spirit_pet_identity_service.dart';
import 'local_account_registry.dart';
import 'user_identity_service.dart';

/// 账号身份编排：User + SpiritPet + 本机 OwnedDevice 注册与角色。
class AccountIdentityService {
  AccountIdentityService._();
  static final AccountIdentityService instance = AccountIdentityService._();

  static const _tag = 'AccountIdentity';
  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _uuid = const Uuid();

  bool _initialized = false;

  Ed25519Identity? _user;
  Ed25519Identity? _pet;

  bool get isInitialized => _initialized;

  Future<Ed25519Identity> userIdentity() async {
    await ensureInitialized();
    return _user!;
  }

  Future<Ed25519Identity> spiritPetIdentity() async {
    await ensureInitialized();
    return _pet!;
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;

    await LocalAccountRegistry.instance.ensureInitialized();
    final accountId = await LocalAccountRegistry.instance.getActiveAccountId();
    if (accountId == null || !await UserIdentityService.instance.existsForAccount(accountId)) {
      throw StateError('No account on this device');
    }

    await LocalDatabaseService().switchAccount(accountId);
    _user = await UserIdentityService.instance.loadOrCreate();
    _pet = await SpiritPetIdentityService.instance.loadOrCreate();

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertIdentityUser(
      id: _user!.fingerprintHex,
      displayName: '',
      publicKey: _user!.publicKey,
      createdAt: _user!.createdAtMs ?? now,
    );
    await _db.upsertSpiritPet(
      id: _pet!.fingerprintHex,
      userId: _user!.fingerprintHex,
      name: 'She',
      publicKey: _pet!.publicKey,
      agentId: SpiritPetIdentityService.instance.linkedAgentId,
      createdAt: _pet!.createdAtMs ?? now,
    );

    await _ensureLocalOwnedDevice();
    _initialized = true;
    _log.info(
      'Account identity ready (user=${_user!.fingerprintHex}, pet=${_pet!.fingerprintHex})',
      tag: _tag,
    );
  }

  Future<OwnedDeviceRecord?> localDevice() => _db.getLocalOwnedDevice();

  Future<OwnedDeviceRecord?> primaryDevice() => _db.getPrimaryDevice();

  Future<List<OwnedDeviceRecord>> ownedDevices() => _db.listOwnedDevices();

  /// 在本机创建新账号（User + 固定灵宠），账号 ID 为 User 公钥指纹。
  Future<String> createAccount({DeviceRole? preferredRole}) async {
    await AccountSessionService.instance.prepareNewAccount();

    _user = await Ed25519Identity.generateFresh();
    _pet = await Ed25519Identity.generateFresh();
    final accountId = _user!.fingerprintHex;

    await Ed25519Identity.importRecord(
      UserIdentityService.storageKeyFor(accountId),
      _user!.encodeRecord(),
    );
    await Ed25519Identity.importRecord(
      SpiritPetIdentityService.storageKeyFor(accountId),
      _pet!.encodeRecord(),
    );

    await LocalAccountRegistry.instance.registerAccount(accountId);
    await LocalDatabaseService().switchAccount(accountId);

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertIdentityUser(
      id: _user!.fingerprintHex,
      displayName: '',
      publicKey: _user!.publicKey,
      createdAt: _user!.createdAtMs ?? now,
    );
    await _db.upsertSpiritPet(
      id: _pet!.fingerprintHex,
      userId: _user!.fingerprintHex,
      name: 'She',
      publicKey: _pet!.publicKey,
      agentId: SpiritPetIdentityService.instance.linkedAgentId,
      createdAt: _pet!.createdAtMs ?? now,
    );

    await _ensureLocalOwnedDevice(preferredRole: preferredRole);
    _initialized = true;
    _log.info(
      'Account created (user=${_user!.fingerprintHex}, pet=${_pet!.fingerprintHex})',
      tag: _tag,
    );
    return _user!.fingerprintHex;
  }

  /// 切换账号前清除内存状态（不删 Secure Storage）。
  void resetInMemory() {
    _initialized = false;
    _user = null;
    _pet = null;
    UserIdentityService.instance.clearCache();
    SpiritPetIdentityService.instance.clearCache();
  }

  Future<String?> accountId() async {
    if (!_initialized) return null;
    return _user?.fingerprintHex;
  }

  /// 导入身份后重置内存缓存并重新登记本机设备。
  Future<void> resetAfterIdentityImport({DeviceRole? preferredRole}) async {
    resetInMemory();
    await _db.clearOwnedDevices();
    await ensureInitialized();
    if (preferredRole != null) {
      await setLocalDeviceRole(preferredRole);
    }
  }

  Future<void> setLocalDeviceRole(DeviceRole role) async {
    final local = await localDevice();
    if (local == null) return;

    if (role == DeviceRole.primary) {
      // 同一账号域只允许一台 Primary：其余降为 app（backup 保持 backup）。
      final all = await _db.listOwnedDevices();
      for (final d in all) {
        if (d.deviceId == local.deviceId) continue;
        if (d.role == DeviceRole.primary) {
          await _db.updateOwnedDeviceRole(d.deviceId, DeviceRole.app);
        }
      }
    }

    await _db.updateOwnedDeviceRole(local.deviceId, role);
    _log.info('Local device role → ${role.wireValue}', tag: _tag);
  }

  Future<DeviceRole> localDeviceRole() async {
    final local = await localDevice();
    return local?.role ?? DeviceRole.app;
  }

  static DeviceRole defaultRoleForPlatform() {
    if (kIsWeb) return DeviceRole.app;
    if (Platform.isAndroid || Platform.isIOS) return DeviceRole.app;
    return DeviceRole.primary;
  }

  Future<void> _ensureLocalOwnedDevice({DeviceRole? preferredRole}) async {
    final pairing = PeerPairingService.instance;
    await pairing.ensureDeviceInfo();
    final deviceId = await pairing.getDeviceId();
    final deviceName = await pairing.getDeviceName();

    final transport = await NoiseIdentity.loadOrCreate();
    final existing = await _db.getOwnedDeviceByDeviceId(deviceId);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (existing != null) {
      await _db.updateOwnedDeviceLastSeen(deviceId, now);
      return;
    }

    final role = preferredRole ?? defaultRoleForPlatform();
    final record = OwnedDeviceRecord(
      id: _uuid.v4(),
      deviceId: deviceId,
      deviceName: deviceName,
      role: role,
      transportPublicKey: transport.publicKey,
      fingerprint: transport.fingerprintHex,
      userId: _user!.fingerprintHex,
      petId: _pet!.fingerprintHex,
      isLocal: true,
      trustedAt: now,
      lastSeenAt: now,
    );
    await _db.upsertOwnedDevice(record);

    // 首台桌面默认 Primary；若已有 Primary 则本机尊重 defaultRole。
    if (role == DeviceRole.primary) {
      final existingPrimary = await _db.getPrimaryDevice();
      if (existingPrimary != null && existingPrimary.deviceId != deviceId) {
        await _db.updateOwnedDeviceRole(deviceId, DeviceRole.app);
      }
    }
  }
}
