import '../../services/secure_key_manager.dart';
import '../../services/she_service.dart';
import '../crypto/ed25519_identity.dart';
import 'local_account_registry.dart';

/// 灵宠（SpiritPet）域身份 — 与内置 She agent 关联的 Ed25519 密钥。
class SpiritPetIdentityService {
  SpiritPetIdentityService._();
  static final SpiritPetIdentityService instance = SpiritPetIdentityService._();

  static const String legacyStorageKey = 'shepaw.spirit_pet.identity.v1';

  static String storageKeyFor(String accountId) => 'shepaw.spirit_pet.identity.$accountId';

  Ed25519Identity? _cached;
  String? _cachedAccountId;

  Future<String> _activeAccountId() async {
    final id = await LocalAccountRegistry.instance.getActiveAccountId();
    if (id == null) throw StateError('No active account');
    return id;
  }

  Future<Ed25519Identity> loadOrCreate() async {
    final accountId = await _activeAccountId();
    if (_cached != null && _cachedAccountId == accountId) return _cached!;

    final key = storageKeyFor(accountId);
    _cached = await Ed25519Identity.loadOrCreate(key);
    _cachedAccountId = accountId;
    return _cached!;
  }

  Future<Ed25519Identity?> peekCached() async => _cached;

  Future<bool> existsForAccount(String accountId) async {
    final raw = await SecureKeyManager.getSecureValue(storageKeyFor(accountId));
    return raw != null && raw.isNotEmpty;
  }

  Future<bool> exists() async {
    if (_cached != null) return true;
    await LocalAccountRegistry.instance.ensureInitialized();
    final accountId = await LocalAccountRegistry.instance.getActiveAccountId();
    if (accountId != null) return existsForAccount(accountId);
    final raw = await SecureKeyManager.getSecureValue(legacyStorageKey);
    return raw != null && raw.isNotEmpty;
  }

  /// 关联的内置 Agent id（She）。
  String get linkedAgentId => SheService.sheId;

  Future<Ed25519Identity> importFromRecord(String record) async {
    final accountId = await _activeAccountId();
    final key = storageKeyFor(accountId);
    _cached = await Ed25519Identity.importRecord(key, record);
    _cachedAccountId = accountId;
    return _cached!;
  }

  void clearCache() {
    _cached = null;
    _cachedAccountId = null;
  }

  Future<void> clearKeysAndCache() async {
    final accountId = await LocalAccountRegistry.instance.getActiveAccountId();
    clearCache();
    if (accountId != null) {
      await SecureKeyManager.deleteSecureValue(storageKeyFor(accountId));
    }
  }
}
