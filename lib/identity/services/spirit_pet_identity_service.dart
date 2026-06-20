import '../../services/secure_key_manager.dart';
import '../../services/she_service.dart';
import '../crypto/ed25519_identity.dart';

/// 灵宠（SpiritPet）域身份 — 与内置 She agent 关联的 Ed25519 密钥。
class SpiritPetIdentityService {
  SpiritPetIdentityService._();
  static final SpiritPetIdentityService instance = SpiritPetIdentityService._();

  static const String storageKey = 'shepaw.spirit_pet.identity.v1';

  Ed25519Identity? _cached;

  Future<Ed25519Identity> loadOrCreate() async {
    if (_cached != null) return _cached!;
    _cached = await Ed25519Identity.loadOrCreate(storageKey);
    return _cached!;
  }

  Future<Ed25519Identity?> peekCached() async => _cached;

  Future<bool> exists() async {
    if (_cached != null) return true;
    final raw = await SecureKeyManager.getSecureValue(storageKey);
    return raw != null && raw.isNotEmpty;
  }

  /// 关联的内置 Agent id（She）。
  String get linkedAgentId => SheService.sheId;

  Future<Ed25519Identity> importFromRecord(String record) async {
    _cached = await Ed25519Identity.importRecord(storageKey, record);
    return _cached!;
  }

  void clearCache() => _cached = null;

  Future<void> clearKeysAndCache() async {
    _cached = null;
    await SecureKeyManager.deleteSecureValue(storageKey);
  }
}
