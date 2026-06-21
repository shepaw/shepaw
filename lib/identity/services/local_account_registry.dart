import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/logger_service.dart';
import '../../services/secure_key_manager.dart';
import '../crypto/ed25519_identity.dart';
import '../models/local_account_entry.dart';
import 'spirit_pet_identity_service.dart';
import 'user_identity_service.dart';

/// 本机多账号注册表：记录已保存账号 ID，并跟踪当前激活账号。
class LocalAccountRegistry {
  LocalAccountRegistry._();
  static final LocalAccountRegistry instance = LocalAccountRegistry._();

  static const _registryKey = 'shepaw.local_accounts.registry.v1';
  static const _activeAccountKey = 'shepaw.local_accounts.active_id';

  final _log = LoggerService();
  bool _migrated = false;

  Future<void> ensureInitialized() async {
    if (_migrated) return;
    await _migrateLegacySingleAccount();
    _migrated = true;
  }

  Future<List<LocalAccountEntry>> listAccounts() async {
    await ensureInitialized();
    final raw = await SecureKeyManager.getSecureValue(_registryKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    final entries = list
        .map((e) => LocalAccountEntry.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.lastUsedAtMs.compareTo(a.lastUsedAtMs));
    return entries;
  }

  Future<bool> hasAnyAccount() async {
    final accounts = await listAccounts();
    return accounts.isNotEmpty;
  }

  Future<String?> getActiveAccountId() async {
    await ensureInitialized();
    return SecureKeyManager.getSecureValue(_activeAccountKey);
  }

  Future<void> setActiveAccountId(String accountId) async {
    await ensureInitialized();
    await SecureKeyManager.saveSecureValue(_activeAccountKey, accountId);
    await _touchAccount(accountId);
  }

  Future<void> registerAccount(String accountId, {String displayName = ''}) async {
    await ensureInitialized();
    final accounts = await listAccounts();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = accounts.where((a) => a.accountId == accountId).toList();
    if (existing.isNotEmpty) {
      await setActiveAccountId(accountId);
      return;
    }
    accounts.add(LocalAccountEntry(
      accountId: accountId,
      displayName: displayName,
      createdAtMs: now,
      lastUsedAtMs: now,
    ));
    await _saveAccounts(accounts);
    await setActiveAccountId(accountId);
    _log.info('Registered local account $accountId', tag: 'LocalAccount');
  }

  Future<void> removeAccount(String accountId) async {
    await ensureInitialized();
    final accounts = await listAccounts();
    accounts.removeWhere((a) => a.accountId == accountId);
    await _saveAccounts(accounts);

    await SecureKeyManager.deleteSecureValue(UserIdentityService.storageKeyFor(accountId));
    await SecureKeyManager.deleteSecureValue(SpiritPetIdentityService.storageKeyFor(accountId));

    final active = await getActiveAccountId();
    if (active == accountId) {
      await SecureKeyManager.deleteSecureValue(_activeAccountKey);
      if (accounts.isNotEmpty) {
        await setActiveAccountId(accounts.first.accountId);
      }
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final accountDir = Directory(join(docsDir.path, 'accounts', accountId));
      if (accountDir.existsSync()) {
        await accountDir.delete(recursive: true);
      }
    } catch (e) {
      _log.warning('Failed to remove account data dir: $e', tag: 'LocalAccount');
    }
  }

  Future<void> _touchAccount(String accountId) async {
    final accounts = await listAccounts();
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (var i = 0; i < accounts.length; i++) {
      if (accounts[i].accountId == accountId) {
        accounts[i] = accounts[i].copyWith(lastUsedAtMs: now);
        changed = true;
        break;
      }
    }
    if (changed) await _saveAccounts(accounts);
  }

  Future<void> _saveAccounts(List<LocalAccountEntry> accounts) async {
    final json = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await SecureKeyManager.saveSecureValue(_registryKey, json);
  }

  /// 将旧版单账号（固定 storage key + 根目录 shepaw.db）迁移到多账号结构。
  Future<void> _migrateLegacySingleAccount() async {
    final existing = await SecureKeyManager.getSecureValue(_registryKey);
    if (existing != null && existing.isNotEmpty) return;

    final legacyUserRaw = await SecureKeyManager.getSecureValue(UserIdentityService.legacyStorageKey);
    if (legacyUserRaw == null || legacyUserRaw.isEmpty) return;

    final user = Ed25519Identity.parseRecord(legacyUserRaw);
    final accountId = user.fingerprintHex;

    final scopedUserKey = UserIdentityService.storageKeyFor(accountId);
    final scopedPetKey = SpiritPetIdentityService.storageKeyFor(accountId);

    if (await SecureKeyManager.getSecureValue(scopedUserKey) == null) {
      await SecureKeyManager.saveSecureValue(scopedUserKey, legacyUserRaw);
    }

    final legacyPetRaw = await SecureKeyManager.getSecureValue(SpiritPetIdentityService.legacyStorageKey);
    if (legacyPetRaw != null &&
        legacyPetRaw.isNotEmpty &&
        await SecureKeyManager.getSecureValue(scopedPetKey) == null) {
      await SecureKeyManager.saveSecureValue(scopedPetKey, legacyPetRaw);
    }

    await _migrateLegacyDatabase(accountId);

    final now = DateTime.now().millisecondsSinceEpoch;
    await _saveAccounts([
      LocalAccountEntry(accountId: accountId, createdAtMs: now, lastUsedAtMs: now),
    ]);
    await SecureKeyManager.saveSecureValue(_activeAccountKey, accountId);
    _log.info('Migrated legacy single account → $accountId', tag: 'LocalAccount');
  }

  Future<void> _migrateLegacyDatabase(String accountId) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final legacyDb = File(join(docsDir.path, 'shepaw.db'));
      if (!await legacyDb.exists()) return;

      final accountDir = Directory(join(docsDir.path, 'accounts', accountId));
      await accountDir.create(recursive: true);
      final targetDb = File(join(accountDir.path, 'shepaw.db'));
      if (!await targetDb.exists()) {
        await legacyDb.rename(targetDb.path);
      }
    } catch (e) {
      _log.warning('Legacy DB migration failed: $e', tag: 'LocalAccount');
    }
  }
}
