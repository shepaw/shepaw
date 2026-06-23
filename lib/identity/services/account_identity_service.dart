import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:meta/meta.dart';
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
import 'sync_role_service.dart';
import 'user_identity_service.dart';

/// 账号身份编排：User + SpiritPet + 本机 OwnedDevice 注册与角色。
class AccountIdentityService {
  AccountIdentityService._();
  static final AccountIdentityService instance = AccountIdentityService._();

  static const _tag = 'AccountIdentity';
  static const _userElectedPrimaryKey = 'user_elected_primary_device_id';
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

  Future<OwnedDeviceRecord?> primaryDevice() async {
    await _repairPrimaryRegistry();
    return _db.getPrimaryDevice();
  }

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

  /// 双 Primary 冲突时 lex 较小 device_id 胜出（无用户指定时）。
  static String primaryWinnerDeviceId(String a, String b) =>
      a.compareTo(b) <= 0 ? a : b;

  Future<String?> userElectedPrimaryDeviceId() async {
    final raw = await _db.getIdentitySyncState(_userElectedPrimaryKey);
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// 在候选 Primary 中解析权威设备（用户指定优先于 lex）。
  Future<String> resolvePrimaryWinnerAmong(Iterable<String> candidateIds) async {
    final ids = candidateIds.toList();
    if (ids.isEmpty) return '';
    if (ids.length == 1) return ids.first;
    final elected = await userElectedPrimaryDeviceId();
    if (elected != null && elected.isNotEmpty && ids.contains(elected)) {
      return elected;
    }
    return ids.reduce(primaryWinnerDeviceId);
  }

  Future<void> _setUserElectedPrimary(String? deviceId) async {
    await _db.setIdentitySyncState(_userElectedPrimaryKey, deviceId ?? '');
  }

  /// 本机是否为账号域唯一权威 Primary（含脑裂自修复）。
  Future<bool> isCanonicalPrimary() async {
    final local = await localDevice();
    if (local == null || local.role != DeviceRole.primary) return false;
    await _repairPrimaryRegistry();
    final primary = await primaryDevice();
    return primary?.deviceId == local.deviceId;
  }

  /// 处理对端 `sync_role_announce`，合并角色并消解双 Primary。
  Future<void> reconcileRemoteDeviceRole({
    required String remoteDeviceId,
    required DeviceRole announcedRole,
    String? deviceName,
  }) async {
    final existing = await _db.getOwnedDeviceByDeviceId(remoteDeviceId);
    if (existing == null) return;

    var effectiveRole = announcedRole;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (announcedRole == DeviceRole.primary) {
      final currentPrimary = await primaryDevice();
      var localDemoted = false;
      if (currentPrimary != null && currentPrimary.deviceId != remoteDeviceId) {
        final winner = await resolvePrimaryWinnerAmong([
          currentPrimary.deviceId,
          remoteDeviceId,
        ]);
        if (winner != remoteDeviceId) {
          effectiveRole = DeviceRole.app;
        } else {
          if (currentPrimary.isLocal) localDemoted = true;
          await _db.updateOwnedDeviceRole(currentPrimary.deviceId, DeviceRole.app);
        }
      }
      if (effectiveRole == DeviceRole.primary) {
        final all = await _db.listOwnedDevices();
        for (final d in all) {
          if (d.deviceId == remoteDeviceId) continue;
          if (d.role == DeviceRole.primary) {
            if (d.isLocal) localDemoted = true;
            await _db.updateOwnedDeviceRole(d.deviceId, DeviceRole.app);
          }
        }
      }
      if (localDemoted) {
        unawaited(SyncRoleService.announceLocalRole());
      }
    }

    await _db.upsertOwnedDevice(existing.copyWith(
      deviceName: deviceName ?? existing.deviceName,
      role: effectiveRole,
      lastSeenAt: now,
    ));
  }

  Future<void> _repairPrimaryRegistry() async {
    final local = await localDevice();
    final all = await _db.listOwnedDevices();
    final primaries = all.where((d) => d.role == DeviceRole.primary).toList();
    if (primaries.length <= 1) return;

    final winnerId = await resolvePrimaryWinnerAmong(
      primaries.map((d) => d.deviceId),
    );
    var localDemoted = false;
    for (final d in primaries) {
      if (d.deviceId != winnerId) {
        if (d.isLocal) localDemoted = true;
        await _db.updateOwnedDeviceRole(d.deviceId, DeviceRole.app);
      }
    }
    _log.warning('Repaired split primary registry → $winnerId', tag: _tag);
    if (localDemoted && local != null) {
      unawaited(SyncRoleService.announceLocalRole());
    }
  }

  Future<void> applyRemoteUserElectedPrimary(String? deviceId) async {
    await _setUserElectedPrimary(deviceId);
  }

  Future<void> setLocalDeviceRole(DeviceRole role) async {
    final local = await localDevice();
    if (local == null) return;

    if (role == DeviceRole.primary) {
      await _setUserElectedPrimary(local.deviceId);
      // 同一账号域只允许一台 Primary：其余降为 app（backup 保持 backup）。
      final all = await _db.listOwnedDevices();
      for (final d in all) {
        if (d.deviceId == local.deviceId) continue;
        if (d.role == DeviceRole.primary) {
          await _db.updateOwnedDeviceRole(d.deviceId, DeviceRole.app);
        }
      }
    } else {
      final elected = await userElectedPrimaryDeviceId();
      if (elected == local.deviceId) {
        await _setUserElectedPrimary(null);
      }
    }

    await _db.updateOwnedDeviceRole(local.deviceId, role);
    _log.info('Local device role → ${role.wireValue}', tag: _tag);
    unawaited(SyncRoleService.announceLocalRole());
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

  /// 测试专用：跳过 SecureKey 初始化，仅激活账号 DB 作用域。
  @visibleForTesting
  Future<void> activateAccountScopeForTests(String accountId) async {
    await _db.switchAccount(accountId);
    _initialized = true;
  }

  @visibleForTesting
  void resetIdentityStateForTests() {
    _initialized = false;
    _user = null;
    _pet = null;
  }
}
