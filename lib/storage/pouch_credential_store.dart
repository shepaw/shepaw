import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/logger_service.dart';
import '../services/secure_key_manager.dart';

/// 主机签发的一张「设备凭据」。
///
/// 主机重启会把登录会话全丢进内存之外，App 拿它换回登录态，不用再输主机密码。
/// 它只对这一台设备的一只袋子有效，30 天过期，改密码 / 解除配对就会失效。
class PouchCredential {
  const PouchCredential({
    required this.pouchId,
    required this.credential,
    this.expiresAtMs = 0,
  });

  final String pouchId;
  final String credential;

  /// 过期时间（毫秒）。0 表示主机没给，交给主机判断。
  final int expiresAtMs;

  bool isExpired(int nowMs) => expiresAtMs > 0 && expiresAtMs <= nowMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pouch_id': pouchId,
        'credential': credential,
        if (expiresAtMs > 0) 'expires_at': expiresAtMs,
      };

  static PouchCredential? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pouchId = (raw['pouch_id'] as String?)?.trim() ?? '';
    final credential = (raw['credential'] as String?)?.trim() ?? '';
    if (pouchId.isEmpty || credential.isEmpty) return null;
    final expires = raw['expires_at'];
    return PouchCredential(
      pouchId: pouchId,
      credential: credential,
      expiresAtMs: expires is int && expires > 0 ? expires : 0,
    );
  }
}

/// 凭据的存放处。和登录 token 一样走系统秘密库，不进普通文件。
abstract class PouchCredentialVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryPouchCredentialVault implements PouchCredentialVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// 与 [SecurePouchTokenVault] 同一套兜底：钥匙串不可用（未签名调试包的
/// −34018）时退回应用目录里的加密文件。
class SecurePouchCredentialVault implements PouchCredentialVault {
  SecurePouchCredentialVault({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.unlocked_this_device,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.unlocked_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    try {
      await SecureKeyManager.deleteSecureValue(key);
    } catch (_) {}
  }

  @override
  Future<String?> read(String key) async {
    try {
      final value = (await _storage.read(key: key))?.trim() ?? '';
      if (value.isNotEmpty) return value;
    } catch (_) {}
    try {
      final value = (await SecureKeyManager.getSecureValue(key))?.trim() ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      return;
    } catch (_) {}
    await SecureKeyManager.saveSecureValue(key, value);
  }
}

/// 每台主机一份凭据。存不进去只记日志，绝不能让登录本身失败。
class PouchCredentialStore {
  PouchCredentialStore({PouchCredentialVault? vault, void Function(String)? log})
      : _vault = vault ?? SecurePouchCredentialVault(),
        _log = log;

  /// 全局共享的一份。生产代码用它；测试直接 new 一个带内存 vault 的。
  static final PouchCredentialStore instance = PouchCredentialStore();

  final PouchCredentialVault _vault;
  final void Function(String)? _log;

  static String keyFor(String hostPeerId) => 'pouch_credential_v1_$hostPeerId';

  Future<PouchCredential?> read(String hostPeerId) async {
    final host = hostPeerId.trim();
    if (host.isEmpty) return null;
    try {
      final raw = await _vault.read(keyFor(host));
      if (raw == null || raw.trim().isEmpty) return null;
      return PouchCredential.fromJson(jsonDecode(raw));
    } catch (error) {
      _warn('读取设备凭据失败：$error');
      return null;
    }
  }

  /// 这张凭据现在能不能用：袋子对得上，而且没过期。
  ///
  /// 它只对这一台主机的一只袋子有效，换主机或者换了袋子就不能拿去续期。
  Future<PouchCredential?> readValid({
    required String hostPeerId,
    required String pouchId,
    required int nowMs,
  }) async {
    final saved = await read(hostPeerId);
    if (saved == null) return null;
    if (saved.pouchId != pouchId.trim()) return null;
    if (saved.isExpired(nowMs)) return null;
    return saved;
  }

  Future<void> save({
    required String hostPeerId,
    required String pouchId,
    required String credential,
    int expiresAtMs = 0,
  }) async {
    final host = hostPeerId.trim();
    final pouch = pouchId.trim();
    final value = credential.trim();
    if (host.isEmpty || pouch.isEmpty || value.isEmpty) return;
    final body = jsonEncode(
      PouchCredential(
        pouchId: pouch,
        credential: value,
        expiresAtMs: expiresAtMs,
      ).toJson(),
    );
    try {
      await _vault.write(keyFor(host), body);
    } catch (error) {
      _warn('保存设备凭据失败：$error');
    }
  }

  Future<void> delete(String hostPeerId) async {
    final host = hostPeerId.trim();
    if (host.isEmpty) return;
    try {
      await _vault.delete(keyFor(host));
    } catch (error) {
      _warn('删除设备凭据失败：$error');
    }
  }

  void _warn(String message) {
    final log = _log;
    if (log != null) {
      log(message);
      return;
    }
    LoggerService().warning(message, tag: 'PouchCredential');
  }
}
