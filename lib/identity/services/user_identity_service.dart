import '../../services/secure_key_manager.dart';
import '../crypto/ed25519_identity.dart';

/// 主人（User）域身份 — Ed25519 签名密钥。
class UserIdentityService {
  UserIdentityService._();
  static final UserIdentityService instance = UserIdentityService._();

  static const String storageKey = 'shepaw.user.identity.v1';

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

  Future<Ed25519Identity> importFromRecord(String record) async {
    _cached = await Ed25519Identity.importRecord(storageKey, record);
    return _cached!;
  }

  void clearCache() => _cached = null;

  /// 清除本机账号密钥（切换账号前调用）。
  Future<void> clearKeysAndCache() async {
    _cached = null;
    await SecureKeyManager.deleteSecureValue(storageKey);
  }
}
