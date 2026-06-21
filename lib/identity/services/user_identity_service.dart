import '../../services/secure_key_manager.dart';
import '../crypto/ed25519_identity.dart';
import 'local_account_registry.dart';

/// 主人（User）域身份 — Ed25519 签名密钥。
class UserIdentityService {
  UserIdentityService._();
  static final UserIdentityService instance = UserIdentityService._();

  static const String legacyStorageKey = 'shepaw.user.identity.v1';

  static String storageKeyFor(String accountId) => 'shepaw.user.identity.$accountId';

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

  /// 清除当前激活账号密钥（切换/删除账号前调用）。
  Future<void> clearKeysAndCache() async {
    final accountId = await LocalAccountRegistry.instance.getActiveAccountId();
    clearCache();
    if (accountId != null) {
      await SecureKeyManager.deleteSecureValue(storageKeyFor(accountId));
    }
  }
}
