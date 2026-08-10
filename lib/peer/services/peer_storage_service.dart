import 'package:sqflite/sqflite.dart';
import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import '../models/peer_hub_pending_approval.dart';
import '../models/peer_store_share.dart';
import '../../services/local_storage_service.dart';
import '../../services/logger_service.dart';
import '../../storage/store_protocol.dart' show StoreSpace, TrustLevel;

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
        pairing_role TEXT,
        trust_level TEXT NOT NULL DEFAULT 'owner'
      )
    ''');
    // 老库迁移：仅当列不存在时 ALTER，避免每次启动刷 sqflite 原生 duplicate column 日志。
    final columns = await db.rawQuery('PRAGMA table_info(paired_peers)');
    final columnNames = columns.map((r) => r['name'] as String).toSet();
    if (!columnNames.contains('pairing_role')) {
      await db.execute('ALTER TABLE paired_peers ADD COLUMN pairing_role TEXT');
    }
    if (!columnNames.contains('trust_level')) {
      await db.execute(
          "ALTER TABLE paired_peers ADD COLUMN trust_level TEXT NOT NULL DEFAULT 'owner'");
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
    // 本机储物袋分享给配对设备（space + path 前缀；path='' 表示整区）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peer_store_shares (
        peer_id TEXT NOT NULL,
        space TEXT NOT NULL,
        path TEXT NOT NULL DEFAULT '',
        shared INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (peer_id, space, path)
      )
    ''');
    // 对端宣布「对方分享给我」的缓存（供远程浏览器渲染）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peer_store_shares_inbound (
        peer_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        space TEXT NOT NULL,
        path TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (peer_id, space, path)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peer_hub_pending_approvals (
        approval_id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        task_id TEXT NOT NULL DEFAULT '',
        channel_id TEXT NOT NULL,
        approval_data_json TEXT NOT NULL DEFAULT '{}',
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        selected_action_id TEXT,
        selected_action_label TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_peer_hub_pending_status ON peer_hub_pending_approvals(status, created_at DESC)',
    );
    await _migrateOwnerStoreSharesIfNeeded(db);
    _tablesReady = true;
    _log.debug('P2P tables ensured', tag: _tag);
  }

  /// 存量 owner 且无出站分享记录 → 写入 sharedReadable 整区，保持互读行为。
  Future<void> _migrateOwnerStoreSharesIfNeeded(Database db) async {
    final peers = await db.query(
      'paired_peers',
      columns: ['id', 'trust_level'],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in peers) {
      final peerId = row['id'] as String;
      final trust = row['trust_level'] as String? ?? TrustLevel.owner;
      if (trust != TrustLevel.owner) continue;
      final existing = await db.query(
        'peer_store_shares',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      final batch = db.batch();
      for (final space in StoreSpace.sharedReadable) {
        batch.insert(
          'peer_store_shares',
          {
            'peer_id': peerId,
            'space': space,
            'path': '',
            'shared': 1,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    }
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

  /// 设置配对信任分级（owner | friend，docs/storage_space_plan.md §4）。
  Future<void> setTrustLevel(String peerId, String trustLevel) async {
    assert(trustLevel == 'owner' || trustLevel == 'friend');
    final db = await _db;
    await db.update(
      'paired_peers',
      {'trust_level': trustLevel},
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// 删除配对（同时删除消息记录与分享决定）
  Future<void> removePeer(String peerId) async {
    final db = await _db;
    await db.delete('peer_messages', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete('peer_agent_shares', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete('peer_store_shares', where: 'peer_id = ?', whereArgs: [peerId]);
    await db.delete(
        'peer_store_shares_inbound', where: 'peer_id = ?', whereArgs: [peerId]);
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

  // ── 储物袋分享决定（host 侧：本机 space/path 分享给哪些配对设备） ─────────

  /// 该设备是否已有任意出站储物袋分享记录。
  Future<bool> hasAnyStoreShare(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_store_shares',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 获取分享给该设备的允许项（仅 shared=1）。
  Future<List<PeerStoreShareEntry>> getSharedStoreEntries(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_store_shares',
      where: 'peer_id = ? AND shared = 1',
      whereArgs: [peerId],
    );
    return [
      for (final r in rows)
        PeerStoreShareEntry(
          space: r['space'] as String,
          path: r['path'] as String? ?? '',
          shared: true,
        ),
    ];
  }

  /// ACL 用白名单。
  Future<PeerStoreShareAllowlist> getSharedStoreAllowlist(String peerId) async {
    final entries = await getSharedStoreEntries(peerId);
    return PeerStoreShareAllowlist.fromEntries(entries);
  }

  /// 入站 ACL 用的有效白名单：owner 且从未配置出站分享时，等同默认整区
  /// （扫码方旧配对未写表时仍可互读；用户写过 shared=0 行则不回退）。
  Future<PeerStoreShareAllowlist> effectiveOutboundAllowlist(
    String peerId,
  ) async {
    final list = await getSharedStoreAllowlist(peerId);
    if (!list.isEmpty) return list;
    final peer = await getPeerById(peerId);
    if (peer != null &&
        peer.trustLevel == TrustLevel.owner &&
        !await hasAnyStoreShare(peerId)) {
      return PeerStoreShareAllowlist.ownerDefaults();
    }
    return list;
  }

  /// 设置页：该设备全部分享行（含 shared=0）。
  Future<List<PeerStoreShareEntry>> getStoreShares(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_store_shares',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return [
      for (final r in rows)
        PeerStoreShareEntry(
          space: r['space'] as String,
          path: r['path'] as String? ?? '',
          shared: (r['shared'] as int?) == 1,
        ),
    ];
  }

  /// 用完整条目列表替换该 peer 的出站分享（先删后写）。
  Future<void> replaceStoreShares(
    String peerId,
    Iterable<PeerStoreShareEntry> entries,
  ) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete('peer_store_shares', where: 'peer_id = ?', whereArgs: [peerId]);
    final batch = db.batch();
    for (final e in entries) {
      if (e.space.isEmpty) continue;
      batch.insert(
        'peer_store_shares',
        {
          'peer_id': peerId,
          'space': e.space,
          'path': e.path,
          'shared': e.shared ? 1 : 0,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 写入/更新单条分享（整区或某一 path 前缀）。
  Future<void> setStoreShare(
    String peerId, {
    required String space,
    String path = '',
    required bool shared,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (shared && path.isEmpty) {
      // 整区分享：清掉同 space 下的 path 细项，避免歧义
      await db.delete(
        'peer_store_shares',
        where: 'peer_id = ? AND space = ? AND path != ?',
        whereArgs: [peerId, space, ''],
      );
    }
    if (!shared && path.isEmpty) {
      await db.delete(
        'peer_store_shares',
        where: 'peer_id = ? AND space = ?',
        whereArgs: [peerId, space],
      );
      await db.insert(
        'peer_store_shares',
        {
          'peer_id': peerId,
          'space': space,
          'path': '',
          'shared': 0,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }
    await db.insert(
      'peer_store_shares',
      {
        'peer_id': peerId,
        'space': space,
        'path': path,
        'shared': shared ? 1 : 0,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// owner 默认分享条目（sharedReadable 整区；不含 runtime）。
  static List<PeerStoreShareEntry> ownerDefaultStoreShares() => [
        for (final space in StoreSpace.sharedReadable)
          PeerStoreShareEntry(space: space),
      ];

  /// 若 peer 为 owner 且从未配置过出站分享行，写入默认整区分享。
  ///
  /// 用于扫码发起方配对补齐，以及旧配对在重连时回填（与「本人」默认可互读一致）。
  /// 已有任意 `peer_store_shares` 行（含 shared=0）则不改动，避免覆盖用户收窄。
  Future<bool> ensureOwnerDefaultOutboundSharesIfUnset(String peerId) async {
    final peer = await getPeerById(peerId);
    if (peer == null || peer.trustLevel != TrustLevel.owner) return false;
    if (await hasAnyStoreShare(peerId)) return false;
    await replaceStoreShares(peerId, ownerDefaultStoreShares());
    return true;
  }

  // ── 入站分享目录缓存（对端 announce） ───────────────────────────────────

  Future<void> replaceInboundStoreShares(
    String peerId, {
    required String deviceId,
    required Iterable<PeerStoreShareEntry> entries,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete(
      'peer_store_shares_inbound',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    final batch = db.batch();
    for (final e in entries) {
      if (!e.shared || e.space.isEmpty) continue;
      batch.insert(
        'peer_store_shares_inbound',
        {
          'peer_id': peerId,
          'device_id': deviceId,
          'space': e.space,
          'path': e.path,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<PeerStoreShareEntry>> getInboundStoreShares(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_store_shares_inbound',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return [
      for (final r in rows)
        PeerStoreShareEntry(
          space: r['space'] as String,
          path: r['path'] as String? ?? '',
          shared: true,
        ),
    ];
  }

  Future<PeerStoreShareAllowlist> getInboundStoreAllowlist(String peerId) async {
    return PeerStoreShareAllowlist.fromEntries(
        await getInboundStoreShares(peerId));
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

  /// 按 ID 获取单条配对设备消息。
  Future<PeerMessage?> getMessageById(String messageId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PeerMessage.fromJson(rows.first);
  }

  /// 统计 peer 中 timestamp >= [timestamp] 的消息数量（含该时间点）。
  Future<int> countMessagesFromTimestamp(String peerId, int timestamp) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM peer_messages WHERE peer_id = ? AND timestamp >= ?',
      [peerId, timestamp],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 加载足够的历史消息以包含 [messageId]（用于搜索定位）。
  Future<List<PeerMessage>> getMessagesIncluding(
    String peerId,
    String messageId, {
    int paddingAfter = 30,
  }) async {
    final target = await getMessageById(messageId);
    if (target == null) {
      return getMessages(peerId);
    }
    final count = await countMessagesFromTimestamp(peerId, target.timestamp);
    return getMessages(peerId, limit: count + paddingAfter);
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

  /// 搜索配对设备聊天消息（跨设备或限定单个 peer）
  Future<List<PeerMessageSearchResult>> searchMessages({
    required String query,
    String? peerId,
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) {
      return [];
    }

    try {
      final db = await _db;

      var peerFilter = '';
      final args = <dynamic>['%$query%'];
      if (peerId != null) {
        peerFilter = 'AND pm.peer_id = ?';
        args.add(peerId);
      }
      args.add(limit);

      final rows = await db.rawQuery('''
        SELECT pm.*, pp.device_name AS peer_name
        FROM peer_messages pm
        INNER JOIN paired_peers pp ON pm.peer_id = pp.id
        WHERE pm.content LIKE ?
        $peerFilter
        ORDER BY pm.timestamp DESC
        LIMIT ?
      ''', args);

      return rows.map((row) {
        return PeerMessageSearchResult(
          message: PeerMessage.fromJson(row),
          peerName: row['peer_name'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      _log.error('Error searching peer messages: $e', tag: _tag);
      return [];
    }
  }

  // ── Hub pending peer approvals (Phase C) ────────────────────────────────

  static const int defaultApprovalTtlMs = 24 * 60 * 60 * 1000;

  Future<void> saveHubPendingApproval(PeerHubPendingApproval approval) async {
    final db = await _db;
    await db.insert(
      'peer_hub_pending_approvals',
      approval.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PeerHubPendingApproval?> getHubPendingApproval(String approvalId) async {
    final db = await _db;
    final rows = await db.query(
      'peer_hub_pending_approvals',
      where: 'approval_id = ?',
      whereArgs: [approvalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PeerHubPendingApproval.fromMap(rows.first);
  }

  Future<List<PeerHubPendingApproval>> getPendingHubApprovals() async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'peer_hub_pending_approvals',
      where: 'status = ? AND (expires_at IS NULL OR expires_at > ?)',
      whereArgs: ['pending', now],
      orderBy: 'created_at ASC',
    );
    return rows.map(PeerHubPendingApproval.fromMap).toList();
  }

  Future<void> markHubPendingApprovalSubmitted(
    String approvalId, {
    required String selectedActionId,
    String? selectedActionLabel,
  }) async {
    final db = await _db;
    await db.update(
      'peer_hub_pending_approvals',
      {
        'status': 'submitted',
        'selected_action_id': selectedActionId,
        if (selectedActionLabel != null) 'selected_action_label': selectedActionLabel,
      },
      where: 'approval_id = ?',
      whereArgs: [approvalId],
    );
  }

  Future<void> expireStaleHubPendingApprovals() async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'peer_hub_pending_approvals',
      {'status': 'expired'},
      where: 'status = ? AND expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: ['pending', now],
    );
  }
}

/// 配对设备消息搜索结果
class PeerMessageSearchResult {
  final PeerMessage message;
  final String peerName;

  PeerMessageSearchResult({
    required this.message,
    required this.peerName,
  });
}
