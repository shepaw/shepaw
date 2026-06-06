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
        is_blocked INTEGER DEFAULT 0,
        pairing_role TEXT
      )
    ''');
    // 老库迁移：为既有 paired_peers 表补充 pairing_role 列（重复执行会报错，忽略）。
    try {
      await db.execute('ALTER TABLE paired_peers ADD COLUMN pairing_role TEXT');
    } catch (_) {
      // 列已存在
    }
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
    // 每台配对设备的「本机 agent 分享决定」：记录用户是否同意把某个本地 agent
    // 分享给该设备。存在任意一行即代表该设备已被用户确认过一次（用于区分「首次
    // 连接需弹窗确认」与「之后新开放的 agent 默认不分享」）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peer_agent_shares (
        peer_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        shared INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (peer_id, agent_id)
      )
    ''');
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

  /// 删除配对（同时删除消息记录与 agent 分享决定）
  Future<void> removePeer(String peerId) async {
    final db = await _db;
    await db.delete('peer_messages', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete('peer_agent_shares', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete('paired_peers', where: 'id = ?', whereArgs: [peerId]);
    _log.info('Removed peer: $peerId', tag: _tag);
  }

  // ── Agent 分享决定（host 侧：本机 agent 分享给哪些配对设备） ───────────────

  /// 该设备是否已被用户做过至少一次分享决定（用于判断首次连接是否需要弹窗）。
  Future<bool> hasAnyAgentShare(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_agent_shares',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 获取分享给该设备的本机 agent id 集合（仅 shared=1）。
  Future<Set<String>> getSharedAgentIds(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_agent_shares',
      columns: ['agent_id'],
      where: 'peer_id = ? AND shared = 1',
      whereArgs: [peerId],
    );
    return rows.map((r) => r['agent_id'] as String).toSet();
  }

  /// 获取该设备的全部分享决定（agentId → 是否分享），供设置页展示开关状态。
  Future<Map<String, bool>> getAgentShares(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_agent_shares',
      columns: ['agent_id', 'shared'],
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return {
      for (final r in rows) r['agent_id'] as String: (r['shared'] as int) == 1,
    };
  }

  /// 批量写入分享决定（一次确认/同步多个 agent）。
  Future<void> setAgentShares(String peerId, Map<String, bool> shares) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    shares.forEach((agentId, shared) {
      batch.insert(
        'peer_agent_shares',
        {
          'peer_id': peerId,
          'agent_id': agentId,
          'shared': shared ? 1 : 0,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  /// 写入单个 agent 的分享决定。
  Future<void> setAgentShare(String peerId, String agentId, bool shared) async {
    await setAgentShares(peerId, {agentId: shared});
  }

  /// 删除某个 agent 在所有设备上的分享决定（agent 被删除时清理）。
  Future<void> removeAgentShares(String agentId) async {
    final db = await _db;
    await db.delete('peer_agent_shares', where: 'agent_id = ?', whereArgs: [agentId]);
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
