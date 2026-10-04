import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../services/app_paths.dart';
import '../services/secure_key_manager.dart';

/// App 当前登录的袋子。token 是这次登录态，通道加密用它派生密钥。
class PouchSession {
  const PouchSession({
    required this.hubUrl,
    required this.pouchId,
    required this.pouchName,
    required this.hostPeerId,
    this.token = '',
    this.sessionId = '',
    this.expiresAtMs = 0,
  });

  final String hubUrl;
  final String pouchId;
  final String pouchName;
  final String hostPeerId;

  /// 登录成功后服务端发下的 token。只活在内存和系统钥匙串里，不进会话文件。
  final String token;

  /// 服务端登录态 id。密封帧靠它找到密钥。
  final String sessionId;

  final int expiresAtMs;

  bool isLoggedIn(int nowMs) =>
      token.isNotEmpty && sessionId.isNotEmpty && expiresAtMs > nowMs;

  PouchSession copyWith({String? token, String? hubUrl}) {
    return PouchSession(
      hubUrl: hubUrl ?? this.hubUrl,
      pouchId: pouchId,
      pouchName: pouchName,
      hostPeerId: hostPeerId,
      token: token ?? this.token,
      sessionId: sessionId,
      expiresAtMs: expiresAtMs,
    );
  }

  /// 会话文件只记选了哪只袋子。token 不在这里。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'hub_url': hubUrl,
        'pouch_id': pouchId,
        'pouch_name': pouchName,
        'host_peer_id': hostPeerId,
        if (sessionId.isNotEmpty) 'sid': sessionId,
        if (expiresAtMs > 0) 'expires_at': expiresAtMs,
      };

  static PouchSession? fromJson(Map<String, dynamic> json) {
    final hubUrl = (json['hub_url'] as String?)?.trim() ?? '';
    final pouchId = (json['pouch_id'] as String?)?.trim() ?? '';
    final pouchName = (json['pouch_name'] as String?)?.trim() ?? '';
    final hostPeerId = (json['host_peer_id'] as String?)?.trim() ?? '';
    if (hubUrl.isEmpty || pouchId.isEmpty || hostPeerId.isEmpty) return null;
    final expires = json['expires_at'];
    return PouchSession(
      hubUrl: hubUrl,
      pouchId: pouchId,
      pouchName: pouchName.isEmpty ? pouchId : pouchName,
      hostPeerId: hostPeerId,
      sessionId: (json['sid'] as String?)?.trim() ?? '',
      expiresAtMs: expires is int ? expires : 0,
    );
  }
}

/// 袋子登录 token 的存放处。手机和电脑都走系统秘密库，不写进普通文件。
abstract class PouchTokenVault {
  Future<void> write(String sessionId, String token);
  Future<String?> read(String sessionId);
  Future<void> delete(String sessionId);
}

class MemoryPouchTokenVault implements PouchTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String sessionId) async {
    values.remove(sessionId);
  }

  @override
  Future<String?> read(String sessionId) async => values[sessionId];

  @override
  Future<void> write(String sessionId, String token) async {
    values[sessionId] = token;
  }
}

class SecurePouchTokenVault implements PouchTokenVault {
  SecurePouchTokenVault({FlutterSecureStorage? storage})
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

  static String keyFor(String sessionId) => 'pouch_login_$sessionId';

  @override
  Future<void> delete(String sessionId) async {
    try {
      await _storage.delete(key: keyFor(sessionId));
    } catch (_) {}
    try {
      await SecureKeyManager.deleteSecureValue(keyFor(sessionId));
    } catch (_) {}
  }

  @override
  Future<String?> read(String sessionId) async {
    try {
      final value = await _storage.read(key: keyFor(sessionId));
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    } catch (_) {}
    try {
      final value = await SecureKeyManager.getSecureValue(keyFor(sessionId));
      final trimmed = value?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String sessionId, String token) async {
    try {
      await _storage.write(key: keyFor(sessionId), value: token);
      return;
    } catch (_) {}
    // 未签名的调试包没有钥匙串权限（-34018），退回应用目录里的加密文件。
    await SecureKeyManager.saveSecureValue(keyFor(sessionId), token);
  }
}

class PouchSessionStore {
  PouchSessionStore(this.file, {PouchTokenVault? vault})
      : vault = vault ?? SecurePouchTokenVault();

  final File file;
  final PouchTokenVault vault;

  /// 测试替换读取，避免碰到应用目录。
  @visibleForTesting
  static Future<PouchSession?> Function()? readOverride;

  static Future<File> appFile() async {
    final docs = await AppPaths.documents();
    return File(p.join(docs.path, 'shepaw', 'pouch_session.json'));
  }

  static Future<PouchSession?> readActive() async {
    final override = readOverride;
    if (override != null) return override();
    return PouchSessionStore(await appFile()).load();
  }

  Future<PouchSession?> load() async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final raw = decoded.cast<String, dynamic>();
    final session = PouchSession.fromJson(raw);
    if (session == null) return null;
    final legacy = (raw['token'] as String?)?.trim() ?? '';
    if (legacy.isNotEmpty && session.sessionId.isNotEmpty) {
      await vault.write(session.sessionId, legacy);
      await _writeMeta(session);
      return session.copyWith(token: legacy);
    }
    if (session.sessionId.isEmpty) return session;
    final token = await vault.read(session.sessionId);
    return session.copyWith(token: token ?? '');
  }

  Future<void> save(PouchSession session) async {
    if (session.sessionId.isNotEmpty && session.token.isNotEmpty) {
      await vault.write(session.sessionId, session.token);
    }
    await _writeMeta(session);
  }

  /// 退出登录：钥匙串里的 token 和会话文件一起清掉。
  Future<void> forget() async {
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final sid = (decoded['sid'] as String?)?.trim() ?? '';
          if (sid.isNotEmpty) await vault.delete(sid);
        }
      } catch (_) {}
      await file.delete();
    }
  }

  Future<void> _writeMeta(PouchSession session) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(session.toJson()));
  }
}
