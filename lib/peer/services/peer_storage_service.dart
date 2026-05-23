import 'package:sqflite/sqflite.dart';
import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import '../../services/local_storage_service.dart';
import '../../services/logger_service.dart';

/// P2P 配对设备和消息的持久化存储服务
class PeerStorageService {
  static final PeerStorageService _instance = PeerStorageService._internal();
  factory PeerStorageService() => _instance;
  PeerStorageService._internal();

  static const _tag = 'PeerStorage';
  final _log = LoggerService();
  final _localStorage = LocalStorageService();

  /// 是否已初始化表
  bool _tablesReady = false;

  /// 获取数据库（确保表已创建）
  Future<Database> get _db async {
    if (!_tablesReady) {
      await ensureTables();
    }
    return _localStorage.database;
  }

  /// 确保 P2P 表已创建（首次访问时自动调用）
  Future<void> ensureTables() async {
    if (_tablesReady) return;
    final db = await _localStorage.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS paired_peers (
        id TEXT PRIMARY KEY,
        device_name TEXT NOT NULL,
        device_id TEXT NOT NULL,
        public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        channel_endpoint TEXT,
        local_endpoint TEXT,
        paired_at INTEGER NOT NULL,
        last_seen INTEGER,
        is_blocked INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peer_messages (
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'text',
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        delivery TEXT NOT NULL DEFAULT 'pending',
        FOREIGN KEY (peer_id) REFERENCES paired_peers (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_peer_messages_peer ON peer_messages(peer_id, timestamp DESC)',
    );
    _tablesReady = true;
    _log.debug('P2P tables ensured', tag: _tag);
  }

  // ── PairedPeer CRUD ─────────────────────────────────────────────────────

  /// 保存配对信息（插入或更新）
  Future<void> savePeer(PairedPeer peer) async {
    final db = await _db;
    await db.insert(
      'paired_peers',
      peer.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.debug('Saved peer: ${peer.deviceName} (${peer.fingerprint})', tag: _tag);
  }

  /// 获取所有已配对设备
  Future<List<PairedPeer>> loadAllPeers() async {
    final db = await _db;
    final rows = await db.query('paired_peers', orderBy: 'paired_at DESC');
    return rows.map((row) => PairedPeer.fromJson(row)).toList();
  }

  /// 根据 ID 获取配对设备
  Future<PairedPeer?> getPeerById(String id) async {
    final db = await _db;
    final rows = await db.query('paired_peers', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return PairedPeer.fromJson(rows.first);
  }

  /// 根据指纹查找配对设备
  Future<PairedPeer?> getPeerByFingerprint(String fingerprint) async {
    final db = await _db;
    final rows = await db.query(
      'paired_peers',
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
    if (rows.isEmpty) return null;
    return PairedPeer.fromJson(rows.first);
  }

  /// 根据 deviceId 查找配对设备
  Future<PairedPeer?> getPeerByDeviceId(String deviceId) async {
    final db = await _db;
    final rows = await db.query(
      'paired_peers',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    if (rows.isEmpty) return null;
    return PairedPeer.fromJson(rows.first);
  }

  /// 更新最后在线时间
  Future<void> updateLastSeen(String peerId, int timestamp) async {
    final db = await _db;
    await db.update(
      'paired_peers',
      {'last_seen': timestamp},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 更新 Channel 端点
  Future<void> updateChannelEndpoint(String peerId, String endpoint) async {
    final db = await _db;
    await db.update(
      'paired_peers',
      {'channel_endpoint': endpoint},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 更新内网端点
  Future<void> updateLocalEndpoint(String peerId, String endpoint) async {
    final db = await _db;
    await db.update(
      'paired_peers',
      {'local_endpoint': endpoint},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 屏蔽/解除屏蔽
  Future<void> setBlocked(String peerId, bool blocked) async {
    final db = await _db;
    await db.update(
      'paired_peers',
      {'is_blocked': blocked ? 1 : 0},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 修改设备备注名
  Future<void> updateDeviceName(String peerId, String name) async {
    final db = await _db;
    await db.update(
      'paired_peers',
      {'device_name': name},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 删除配对（同时删除消息记录）
  Future<void> removePeer(String peerId) async {
    final db = await _db;
    await db.delete('peer_messages', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete('paired_peers', where: 'id = ?', whereArgs: [peerId]);
    _log.info('Removed peer: $peerId', tag: _tag);
  }

  // ── PeerMessage CRUD ────────────────────────────────────────────────────

  /// 保存消息
  Future<void> saveMessage(PeerMessage message) async {
    final db = await _db;
    await db.insert(
      'peer_messages',
      message.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取指定配对设备的消息列表（分页，按时间倒序）
  Future<List<PeerMessage>> getMessages(
    String peerId, {
    int limit = 50,
    int? beforeTimestamp,
  }) async {
    final db = await _db;
    String where = 'peer_id = ?';
    List<dynamic> whereArgs = [peerId];

    if (beforeTimestamp != null) {
      where += ' AND timestamp < ?';
      whereArgs.add(beforeTimestamp);
    }

    final rows = await db.query(
      'peer_messages',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map((row) => PeerMessage.fromJson(row)).toList();
  }

  /// 更新消息投递状态
  Future<void> updateMessageDelivery(String messageId, PeerMessageDelivery delivery) async {
    final db = await _db;
    await db.update(
      'peer_messages',
      {'delivery': delivery.toJson()},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 获取未发送的消息（用于离线队列重发）
  Future<List<PeerMessage>> getPendingMessages(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_messages',
      where: "peer_id = ? AND delivery = 'pending'",
      whereArgs: [peerId],
      orderBy: 'timestamp ASC',
    );
    return rows.map((row) => PeerMessage.fromJson(row)).toList();
  }

  /// 删除指定设备的所有消息
  Future<void> deleteAllMessages(String peerId) async {
    final db = await _db;
    await db.delete('peer_messages', where: 'peer_id = ?', whereArgs: [peerId]);
  }
}
