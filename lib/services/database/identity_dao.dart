import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../identity/models/app_cache_policy.dart';
import '../../identity/models/device_role.dart';
import '../../identity/models/owned_device_record.dart';
import '../../identity/models/ownership_bond.dart';
import '../local_database_service.dart';

/// 账号身份域 SQLite 访问（user / spirit_pet / owned_devices / bonds / sync）。
extension IdentityDao on LocalDatabaseService {
  // ── User profile row ─────────────────────────────────────────────────────

  Future<void> upsertIdentityUser({
    required String id,
    required String displayName,
    required List<int> publicKey,
    required int createdAt,
  }) async {
    final db = await database;
    await db.insert(
      'identity_user',
      {
        'id': id,
        'display_name': displayName,
        'public_key': publicKey,
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getIdentityUser(String id) async {
    final db = await database;
    final rows = await db.query('identity_user', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // ── Spirit pet row ───────────────────────────────────────────────────────

  Future<void> upsertSpiritPet({
    required String id,
    required String userId,
    required String name,
    required List<int> publicKey,
    required String agentId,
    required int createdAt,
  }) async {
    final db = await database;
    await db.insert(
      'identity_spirit_pet',
      {
        'id': id,
        'user_id': userId,
        'name': name,
        'public_key': publicKey,
        'agent_id': agentId,
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getSpiritPet(String id) async {
    final db = await database;
    final rows = await db.query('identity_spirit_pet', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> getSpiritPetForUser(String userId) async {
    final db = await database;
    final rows = await db.query('identity_spirit_pet', where: 'user_id = ?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // ── Owned devices ────────────────────────────────────────────────────────

  Future<void> upsertOwnedDevice(OwnedDeviceRecord device) async {
    final db = await database;
    await db.insert('identity_owned_devices', device.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<OwnedDeviceRecord?> getOwnedDeviceByDeviceId(String deviceId) async {
    final db = await database;
    final rows = await db.query('identity_owned_devices', where: 'device_id = ?', whereArgs: [deviceId], limit: 1);
    if (rows.isEmpty) return null;
    return OwnedDeviceRecord.fromMap(rows.first);
  }

  Future<OwnedDeviceRecord?> getLocalOwnedDevice() async {
    final db = await database;
    final rows = await db.query('identity_owned_devices', where: 'is_local = 1', limit: 1);
    if (rows.isEmpty) return null;
    return OwnedDeviceRecord.fromMap(rows.first);
  }

  Future<List<OwnedDeviceRecord>> listOwnedDevices() async {
    final db = await database;
    final rows = await db.query('identity_owned_devices', orderBy: 'trusted_at ASC');
    return rows.map((r) => OwnedDeviceRecord.fromMap(r)).toList();
  }

  Future<void> updateOwnedDeviceRole(String deviceId, DeviceRole role) async {
    final db = await database;
    await db.update('identity_owned_devices', {'role': role.wireValue}, where: 'device_id = ?', whereArgs: [deviceId]);
  }

  Future<void> updateOwnedDeviceLastSeen(String deviceId, int timestamp) async {
    final db = await database;
    await db.update('identity_owned_devices', {'last_seen_at': timestamp}, where: 'device_id = ?', whereArgs: [deviceId]);
  }

  Future<OwnedDeviceRecord?> getPrimaryDevice() async {
    final db = await database;
    final rows = await db.query(
      'identity_owned_devices',
      where: 'role = ?',
      whereArgs: [DeviceRole.primary.wireValue],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return OwnedDeviceRecord.fromMap(rows.first);
  }

  Future<void> clearNonPrimaryRoles() async {
    final db = await database;
    await db.update(
      'identity_owned_devices',
      {'role': DeviceRole.app.wireValue},
      where: 'role = ?',
      whereArgs: [DeviceRole.primary.wireValue],
    );
  }

  // ── Ownership bond ───────────────────────────────────────────────────────

  Future<void> saveOwnershipBond(OwnershipBond bond) async {
    final db = await database;
    await db.insert('identity_ownership_bonds', bond.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<OwnershipBond?> getOwnershipBond(String petId) async {
    final db = await database;
    final rows = await db.query('identity_ownership_bonds', where: 'pet_id = ?', whereArgs: [petId], limit: 1);
    if (rows.isEmpty) return null;
    return OwnershipBond.fromMap(rows.first);
  }

  // ── Sync state KV ────────────────────────────────────────────────────────

  Future<void> setIdentitySyncState(String key, String value) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'identity_sync_state',
      {'key': key, 'value': value, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getIdentitySyncState(String key) async {
    final db = await database;
    final rows = await db.query('identity_sync_state', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  // ── App cache policy ─────────────────────────────────────────────────────

  static const _cachePolicyKey = 'app_cache_policy';

  Future<AppCachePolicy> getAppCachePolicy() async {
    final raw = await getIdentitySyncState(_cachePolicyKey);
    if (raw == null || raw.isEmpty) return const AppCachePolicy();
    return AppCachePolicy.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> setAppCachePolicy(AppCachePolicy policy) async {
    await setIdentitySyncState(_cachePolicyKey, jsonEncode(policy.toJson()));
  }

  // ── Outbound queue (App → Primary) ───────────────────────────────────────

  Future<void> enqueueOutboundEvent({
    required String id,
    required String domain,
    required String payloadJson,
  }) async {
    final db = await database;
    await db.insert(
      'identity_outbound_queue',
      {
        'id': id,
        'domain': domain,
        'payload': payloadJson,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'acked': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> discardOutboundEvent(String id) async {
    final db = await database;
    await db.delete('identity_outbound_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> listPendingOutbound({int limit = 100}) async {
    final db = await database;
    return db.query(
      'identity_outbound_queue',
      where: 'acked = 0',
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> markOutboundAcked(String id) async {
    final db = await database;
    await db.update('identity_outbound_queue', {'acked': 1}, where: 'id = ?', whereArgs: [id]);
  }

  // ── Blob outbound queue (App → Primary 附件重试) ─────────────────────────

  Future<void> enqueueBlobOutbound({required String relativePath}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'identity_blob_outbound_queue',
      {
        'id': relativePath,
        'relative_path': relativePath,
        'created_at': now,
        'acked': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> listPendingBlobOutbound({int limit = 20}) async {
    final db = await database;
    return db.query(
      'identity_blob_outbound_queue',
      where: 'acked = 0',
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> markBlobOutboundAcked(String relativePath) async {
    final db = await database;
    await db.update(
      'identity_blob_outbound_queue',
      {'acked': 1},
      where: 'relative_path = ?',
      whereArgs: [relativePath],
    );
  }

  Future<int> countPendingOutbound() async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) as c FROM identity_outbound_queue WHERE acked = 0',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> countPendingBlobOutbound() async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) as c FROM identity_blob_outbound_queue WHERE acked = 0',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  // ── Sync push outbox (Primary → App/Backup，带 ack 重试) ─────────────────

  Future<void> enqueueSyncPushOutbox({
    required String pushId,
    required String targetDeviceId,
    required String payloadJson,
  }) async {
    final db = await database;
    await db.insert(
      'identity_sync_push_outbox',
      {
        'id': pushId,
        'target_device_id': targetDeviceId,
        'payload': payloadJson,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'acked': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markSyncPushAcked(String pushId) async {
    final db = await database;
    await db.update(
      'identity_sync_push_outbox',
      {'acked': 1},
      where: 'id = ?',
      whereArgs: [pushId],
    );
  }

  Future<List<Map<String, dynamic>>> listPendingSyncPushForDevice(
    String targetDeviceId, {
    int limit = 20,
  }) async {
    final db = await database;
    return db.query(
      'identity_sync_push_outbox',
      where: 'target_device_id = ? AND acked = 0',
      whereArgs: [targetDeviceId],
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  // ── Backup commit relay queue (Backup → Primary) ─────────────────────────

  Future<void> enqueueBackupRelayEvent({required String id, required String payloadJson}) async {
    final db = await database;
    await db.insert(
      'identity_backup_relay_queue',
      {
        'id': id,
        'payload': payloadJson,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'relayed': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markBackupRelayAcked(String id) async {
    final db = await database;
    await db.update(
      'identity_backup_relay_queue',
      {'relayed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> listPendingBackupRelay({int limit = 50}) async {
    final db = await database;
    return db.query(
      'identity_backup_relay_queue',
      where: 'relayed = 0',
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }
}
