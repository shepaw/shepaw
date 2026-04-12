import 'dart:io' show Platform, File, Directory;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart' as remote_agent;
import 'she_profile_database_service.dart';
import 'she_memory_db_service.dart';
import 'minds_database_service.dart';
import 'agent_memory_db_service.dart';
import '../task/models/scheduled_task.dart';
import 'logger_service.dart';
/// 本地数据库服务 - 使用 SQLite 存储所有数据
class LocalDatabaseService {
  static final LocalDatabaseService _instance = LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _database;
  final _uuid = const Uuid();

  /// 生成UUID
  String _generateUuid() => _uuid.v4();

  /// 获取数据库实例
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// 初始化数据库
  Future<Database> _initDatabase() async {
    String path;

    if (kIsWeb) {
      // Web平台使用sqflite_common_ffi
      return await openDatabase(
        'shepaw',
        version: 21,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      // Windows/Linux 使用 sqflite_common_ffi
      final directory = await getApplicationDocumentsDirectory();
      path = join(directory.path, 'shepaw.db');
      return await openDatabase(
        path,
        version: 21,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } else {
      // 移动平台使用sqflite
      final directory = await getApplicationDocumentsDirectory();
      path = join(directory.path, 'shepaw.db');

      return await openDatabase(
        path,
        version: 21,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }
  }

  /// 创建数据库表
  Future<void> _onCreate(Database db, int version) async {
    // 用户敏感信息 KV 存储表
    await db.execute('''
      CREATE TABLE user (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // Agent 表（远端助手）
    await db.execute('''
      CREATE TABLE agents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar TEXT DEFAULT '🤖',
        bio TEXT,

        -- Connection
        token TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        protocol TEXT NOT NULL,
        connection_type TEXT NOT NULL,

        -- Status
        status TEXT DEFAULT 'offline',
        last_heartbeat INTEGER,
        connected_at INTEGER,

        -- Config
        capabilities TEXT,
        metadata TEXT,
        is_pinned INTEGER DEFAULT 0,

        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // A2A Agent Card 缓存表
    await db.execute('''
      CREATE TABLE agent_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id TEXT UNIQUE NOT NULL,
        card_data TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        FOREIGN KEY (agent_id) REFERENCES agents (id) ON DELETE CASCADE
      )
    ''');

    // 通用任务表 (支持 A2A 和其他协议)
    await db.execute('''
      CREATE TABLE tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT UNIQUE NOT NULL,
        agent_id TEXT NOT NULL,
        instruction TEXT NOT NULL,
        state TEXT NOT NULL,
        request_data TEXT NOT NULL,
        response_data TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (agent_id) REFERENCES agents (id) ON DELETE CASCADE
      )
    ''');

    // Channel 表
    await db.execute('''
      CREATE TABLE channels (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        type TEXT NOT NULL,
        avatar_path TEXT,
        is_private INTEGER DEFAULT 0,
        parent_group_id TEXT,
        system_prompt TEXT,
        max_loop_rounds INTEGER,
        mention_mode TEXT,
        planning_mode INTEGER DEFAULT 0,
        flow_mode INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT NOT NULL
      )
    ''');

    // Channel 成员表
    await db.execute('''
      CREATE TABLE channel_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        role TEXT DEFAULT 'member',
        group_bio TEXT,
        joined_at TEXT NOT NULL,
        UNIQUE(channel_id, agent_id),
        FOREIGN KEY (channel_id) REFERENCES channels (id) ON DELETE CASCADE,
        FOREIGN KEY (agent_id) REFERENCES agents (id) ON DELETE CASCADE
      )
    ''');

    // 消息表
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_type TEXT NOT NULL,
        sender_name TEXT NOT NULL,
        content TEXT NOT NULL,
        message_type TEXT DEFAULT 'text',
        metadata TEXT,
        reply_to_id TEXT,
        created_at TEXT NOT NULL,
        is_read INTEGER DEFAULT 0,
        FOREIGN KEY (channel_id) REFERENCES channels (id) ON DELETE CASCADE
      )
    ''');

    // Agent 对话请求表
    await db.execute('''
      CREATE TABLE conversation_requests (
        id TEXT PRIMARY KEY,
        requester_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        purpose TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        metadata TEXT,
        requested_at TEXT NOT NULL,
        responded_at TEXT,
        response_reason TEXT,
        FOREIGN KEY (requester_id) REFERENCES agents (id) ON DELETE CASCADE,
        FOREIGN KEY (target_id) REFERENCES agents (id) ON DELETE CASCADE
      )
    ''');

    // 文件/资源表
    await db.execute('''
      CREATE TABLE resources (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_type TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        mime_type TEXT,
        thumbnail_path TEXT,
        owner_id TEXT NOT NULL,
        owner_type TEXT NOT NULL,
        created_at TEXT NOT NULL,
        metadata TEXT
      )
    ''');

    // 创建索引 (P0: 性能优化)
    await db.execute('CREATE INDEX idx_agents_token ON agents(token)');
    await db.execute('CREATE INDEX idx_agents_status ON agents(status)');
    await db.execute('CREATE INDEX idx_agents_last_heartbeat ON agents(last_heartbeat)');
    await db.execute('CREATE INDEX idx_tasks_agent ON tasks(agent_id)');
    await db.execute('CREATE INDEX idx_tasks_state ON tasks(state)');
    await db.execute('CREATE INDEX idx_tasks_created ON tasks(created_at)');
    await db.execute('CREATE INDEX idx_messages_channel ON messages(channel_id)');
    await db.execute('CREATE INDEX idx_messages_created ON messages(created_at DESC)');
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender_id)');
    await db.execute('CREATE INDEX idx_messages_read ON messages(is_read)');
    await db.execute('CREATE INDEX idx_channels_created_by ON channels(created_by)');
    await db.execute('CREATE INDEX idx_channels_type ON channels(type)');
    await db.execute('CREATE INDEX idx_channel_members_agent ON channel_members(agent_id)');
    await db.execute('CREATE INDEX idx_conversation_requests_status ON conversation_requests(status)');
    await db.execute('CREATE INDEX idx_conversation_requests_target ON conversation_requests(target_id)');
    await db.execute('CREATE INDEX idx_resources_owner ON resources(owner_id, owner_type)');

    // 复合索引用于常见查询
    await db.execute('CREATE INDEX idx_messages_channel_created ON messages(channel_id, created_at DESC)');
    await db.execute('CREATE INDEX idx_tasks_agent_state ON tasks(agent_id, state)');

    // Phase 2 优化: 未读消息查询
    await db.execute('CREATE INDEX idx_messages_channel_read ON messages(channel_id, is_read, created_at DESC)');

    // Phase 2 优化: Agent Card 缓存管理
    await db.execute('CREATE INDEX idx_agent_cards_cached ON agent_cards(cached_at)');

    // Phase 2 优化: 对话请求查询
    await db.execute('CREATE INDEX idx_conversation_requests_target_status ON conversation_requests(target_id, status)');
    await db.execute('CREATE INDEX idx_conversation_requests_requester ON conversation_requests(requester_id, requested_at DESC)');

    // Phase 2 优化: 发送者在 Channel 中的消息
    await db.execute('CREATE INDEX idx_messages_sender_channel ON messages(sender_id, channel_id, created_at DESC)');

    // 工具配置表
    await db.execute('''
      CREATE TABLE tool_configs (
        tool_name TEXT PRIMARY KEY,
        parameter_overrides TEXT,
        has_api_key INTEGER DEFAULT 0,
        enabled INTEGER DEFAULT 1,
        she_exclusive INTEGER DEFAULT 0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // CLI 命令配置表
    await db.execute('''
      CREATE TABLE cli_command_configs (
        command_id TEXT PRIMARY KEY,
        global_enabled INTEGER DEFAULT 1,
        she_only INTEGER DEFAULT 0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // 定时任务表 (v21)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        id TEXT PRIMARY KEY,
        agent_id TEXT,
        channel_id TEXT,
        task_type TEXT NOT NULL,
        description TEXT,
        status TEXT DEFAULT 'pending',
        instruction TEXT NOT NULL,
        parameters TEXT,
        schedule_pattern TEXT NOT NULL,
        last_run_at INTEGER,
        next_run_at INTEGER NOT NULL,
        execution_count INTEGER DEFAULT 0,
        failure_count INTEGER DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_by TEXT NOT NULL,
        execution_target TEXT NOT NULL DEFAULT 'agent',
        agent_ids TEXT,
        mentioned_agent_ids TEXT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_status ON scheduled_tasks(status)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_next_run ON scheduled_tasks(next_run_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_agent ON scheduled_tasks(agent_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_channel ON scheduled_tasks(channel_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_target ON scheduled_tasks(execution_target)');

  }

  /// 数据库升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    
    if (oldVersion < 12) {
      // 版本 11 -> 12: 添加 flow_mode 字段到 channels 表，支持 Flow 模式
      try {
        await db.execute(
          'ALTER TABLE channels ADD COLUMN flow_mode INTEGER DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 13) {
      // 版本 12 -> 13: 加 is_pinned 字段
      // （she_memory 表已迁移到 she_profile.db，此处不再创建）
      try {
        await db.execute('ALTER TABLE agents ADD COLUMN is_pinned INTEGER DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 14) {
      // 版本 13 -> 14: user_profile 表已迁移到 she_profile.db，此处无操作
    }

    if (oldVersion < 16) {
      // 版本 15 -> 16: users 表改为 user KV 存储
      // 删除旧 users 表，创建新 user KV 表
      try {
        await db.execute('DROP TABLE IF EXISTS users');
      } catch (_) {}
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS user (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      } catch (_) {}
    }

    if (oldVersion < 17) {
      // 版本 16 -> 17: 工具全局配置表
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS tool_configs (
            tool_name TEXT PRIMARY KEY,
            parameter_overrides TEXT,
            has_api_key INTEGER DEFAULT 0,
            enabled INTEGER DEFAULT 1,
            she_exclusive INTEGER DEFAULT 0,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      } catch (_) {}
    }

    if (oldVersion < 18) {
      // 版本 17 -> 18: CLI 命令配置表（全局启用/She专属开关）
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cli_command_configs (
            command_id TEXT PRIMARY KEY,
            global_enabled INTEGER DEFAULT 1,
            she_only INTEGER DEFAULT 0,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      } catch (_) {}
    }

    if (oldVersion < 19) {
      // 版本 18 -> 19: tool_configs 表补充 she_exclusive 列
      try {
        await db.execute(
          'ALTER TABLE tool_configs ADD COLUMN she_exclusive INTEGER DEFAULT 0');
      } catch (_) {}
    }


    if (oldVersion < 20) {
      // 版本 19 -> 20: 定时任务表
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS scheduled_tasks (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            channel_id TEXT,
            task_type TEXT NOT NULL,
            description TEXT,
            status TEXT DEFAULT 'pending',
            instruction TEXT NOT NULL,
            parameters TEXT,
            schedule_pattern TEXT NOT NULL,
            last_run_at INTEGER,
            next_run_at INTEGER NOT NULL,
            execution_count INTEGER DEFAULT 0,
            failure_count INTEGER DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            created_by TEXT NOT NULL,
            FOREIGN KEY (agent_id) REFERENCES agents (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_status ON scheduled_tasks(status)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_next_run ON scheduled_tasks(next_run_at)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_agent ON scheduled_tasks(agent_id)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_channel ON scheduled_tasks(channel_id)');
      } catch (e) {
        LoggerService().error('Failed to create scheduled_tasks table', tag: 'Migration', error: e);
      }
    }

    if (oldVersion < 21) {
      // 版本 20 -> 21: scheduled_tasks 支持群任务（execution_target / agent_ids / mentioned_agent_ids）
      // SQLite 不支持直接 DROP CONSTRAINT，使用 rename-create-copy-drop 模式迁移。
      try {
        // 1. 备份旧表
        await db.execute('ALTER TABLE scheduled_tasks RENAME TO scheduled_tasks_v20');
        // 2. 建新表（agent_id 可空、无 FK、三个新列）
        await db.execute('''
          CREATE TABLE scheduled_tasks (
            id TEXT PRIMARY KEY,
            agent_id TEXT,
            channel_id TEXT,
            task_type TEXT NOT NULL,
            description TEXT,
            status TEXT DEFAULT 'pending',
            instruction TEXT NOT NULL,
            parameters TEXT,
            schedule_pattern TEXT NOT NULL,
            last_run_at INTEGER,
            next_run_at INTEGER NOT NULL,
            execution_count INTEGER DEFAULT 0,
            failure_count INTEGER DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            created_by TEXT NOT NULL,
            execution_target TEXT NOT NULL DEFAULT 'agent',
            agent_ids TEXT,
            mentioned_agent_ids TEXT
          )
        ''');
        // 3. 迁移数据（旧数据全部归为 agent 类型，新列填充默认值）
        await db.execute('''
          INSERT INTO scheduled_tasks (
            id, agent_id, channel_id, task_type, description, status,
            instruction, parameters, schedule_pattern, last_run_at, next_run_at,
            execution_count, failure_count, last_error, created_at, updated_at,
            created_by, execution_target, agent_ids, mentioned_agent_ids
          )
          SELECT
            id, agent_id, channel_id, task_type, description, status,
            instruction, parameters, schedule_pattern, last_run_at, next_run_at,
            execution_count, failure_count, last_error, created_at, updated_at,
            created_by, 'agent', NULL, NULL
          FROM scheduled_tasks_v20
        ''');
        // 4. 删除备份表
        await db.execute('DROP TABLE scheduled_tasks_v20');
        // 5. 重建索引
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_status ON scheduled_tasks(status)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_next_run ON scheduled_tasks(next_run_at)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_agent ON scheduled_tasks(agent_id)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_channel ON scheduled_tasks(channel_id)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_target ON scheduled_tasks(execution_target)');
      } catch (e) {
        LoggerService().error('Failed to migrate scheduled_tasks to v21', tag: 'Migration', error: e);
      }
    }

  }

  // ==================== 用户敏感信息 KV 操作 ====================

  /// 写入用户敏感信息（key-value）
  Future<void> setUserValue(String key, String value) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'user',
      {
        'key': key,
        'value': value,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取用户敏感信息
  Future<String?> getUserValue(String key) async {
    final db = await database;
    final results = await db.query(
      'user',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  /// 删除某个用户敏感信息 key
  Future<void> deleteUserValue(String key) async {
    final db = await database;
    await db.delete('user', where: 'key = ?', whereArgs: [key]);
  }

  /// 获取所有用户敏感信息 KV 对
  Future<Map<String, String>> getAllUserValues() async {
    final db = await database;
    final results = await db.query('user');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  /// 清空所有用户敏感信息
  Future<void> clearUserValues() async {
    final db = await database;
    await db.delete('user');
  }

  // ==================== Agent 操作 ====================

  /// 创建 Agent
  Future<void> createAgent(Agent agent, String ownerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'agents',
      {
        'id': agent.id,
        'name': agent.name,
        'avatar': agent.avatar,
        'bio': agent.description,
        'token': agent.metadata?['token'] ?? _generateUuid(),
        'endpoint': agent.metadata?['endpoint'] ?? '',
        'protocol': agent.metadata?['protocol'] ?? 'a2a',
        'connection_type': agent.metadata?['connection_type'] ?? 'http',
        'status': agent.status.state,
        'capabilities': jsonEncode(agent.capabilities),
        'metadata': jsonEncode(agent.metadata ?? {}),
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取所有 Agent
  Future<List<Agent>> getAllAgents() async {
    final db = await database;
    final results = await db.query('agents', orderBy: 'created_at DESC');
    return results.map((map) => _agentFromMap(map)).toList();
  }

  /// 根据 ID 获取 Agent
  Future<Agent?> getAgentById(String id) async {
    final db = await database;
    final results = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    return results.isEmpty ? null : _agentFromMap(results.first);
  }

  /// 更新 Agent
  Future<void> updateAgent(Agent agent) async {
    final db = await database;
    await db.update(
      'agents',
      {
        'name': agent.name,
        'avatar': agent.avatar,
        'bio': agent.description,
        'status': agent.status.state,
        'capabilities': jsonEncode(agent.capabilities ?? []),
        'metadata': jsonEncode(agent.metadata ?? {}),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [agent.id],
    );
  }

  /// 删除 Agent
  Future<void> deleteAgent(String id) async {
    final db = await database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }

  Agent _agentFromMap(Map<String, dynamic> map) {
    final metadata = map['metadata'] != null
        ? Map<String, dynamic>.from(jsonDecode(map['metadata']))
        : <String, dynamic>{};

    return Agent(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Unknown Agent',
      avatar: map['avatar'] ?? '🤖',
      description: map['bio'],
      model: metadata['model'],
      systemPrompt: metadata['system_prompt'],
      temperature: metadata['temperature']?.toDouble(),
      maxTokens: metadata['max_tokens'],
      type: map['protocol'] ?? 'a2a',
      provider: AgentProvider(
        name: metadata['provider_name'] ?? 'Unknown',
        platform: map['protocol'] ?? 'unknown',
        type: metadata['provider_type'] ?? 'llm',
      ),
      status: AgentStatus(
        state: map['status'] ?? 'offline',
        connectedAt: map['connected_at'],
        lastHeartbeat: map['last_heartbeat'],
      ),
      capabilities: map['capabilities'] != null
          ? List<String>.from(jsonDecode(map['capabilities']))
          : [],
      metadata: metadata,
    );
  }

  // ==================== Channel 操作 ====================

  /// 创建 Channel
  Future<void> createChannel(Channel channel, String createdBy) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.insert(
      'channels',
      {
        'id': channel.id,
        'name': channel.name,
        'description': channel.description,
        'type': channel.type,
        'avatar_path': channel.avatar,
        'is_private': channel.isPrivate ? 1 : 0,
        'parent_group_id': channel.parentGroupId,
        'system_prompt': channel.systemPrompt,
        'max_loop_rounds': channel.maxLoopRounds,
        'mention_mode': channel.mentionMode,
        'planning_mode': channel.planningMode ? 1 : 0,
        'flow_mode': channel.flowMode ? 1 : 0,
        'created_at': now,
        'updated_at': now,
        'created_by': createdBy,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // 添加成员（保留角色信息）
    for (final member in channel.members) {
      await addChannelMember(channel.id, member.id, role: member.role, groupBio: member.groupBio);
    }
  }

  /// 获取所有 Channel
  Future<List<Channel>> getAllChannels() async {
    final db = await database;
    final results = await db.query('channels', orderBy: 'created_at DESC');
    
    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 根据 ID 获取 Channel
  Future<Channel?> getChannelById(String id) async {
    final db = await database;
    final results = await db.query('channels', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;

    final members = await getChannelMembers(id);
    return _channelFromMap(results.first, members);
  }

  /// 更新 Channel
  Future<void> updateChannel(Channel channel) async {
    final db = await database;
    await db.update(
      'channels',
      {
        'name': channel.name,
        'description': channel.description,
        'type': channel.type,
        'avatar_path': channel.avatar,
        'is_private': channel.isPrivate ? 1 : 0,
        'system_prompt': channel.systemPrompt,
        'max_loop_rounds': channel.maxLoopRounds,
        'mention_mode': channel.mentionMode,
        'planning_mode': channel.planningMode ? 1 : 0,
        'flow_mode': channel.flowMode ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [channel.id],
    );
  }

  /// 更新 Channel 的 updated_at 时间戳
  Future<void> touchChannelUpdatedAt(String channelId) async {
    final db = await database;
    await db.update(
      'channels',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [channelId],
    );
  }

  /// 删除 Channel
  Future<void> deleteChannel(String id) async {
    final db = await database;
    await db.delete('channels', where: 'id = ?', whereArgs: [id]);
  }

  /// 添加 Channel 成员
  Future<void> addChannelMember(String channelId, String agentId, {String role = 'member', String? groupBio}) async {
    final db = await database;
    await db.insert(
      'channel_members',
      {
        'channel_id': channelId,
        'agent_id': agentId,
        'role': role,
        'group_bio': groupBio,
        'joined_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 更新 Channel 成员角色
  Future<void> updateChannelMemberRole(String channelId, String agentId, String role) async {
    final db = await database;
    await db.update(
      'channel_members',
      {'role': role},
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 更新 Channel 成员的群内能力描述
  Future<void> updateChannelMemberGroupBio(String channelId, String agentId, String? groupBio) async {
    final db = await database;
    await db.update(
      'channel_members',
      {'group_bio': groupBio},
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 移除 Channel 成员
  Future<void> removeChannelMember(String channelId, String agentId) async {
    final db = await database;
    await db.delete(
      'channel_members',
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 获取 Channel 成员 ID 列表
  Future<List<String>> getChannelMemberIds(String channelId) async {
    final db = await database;
    final results = await db.query(
      'channel_members',
      columns: ['agent_id'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    return results.map((r) => r['agent_id'] as String).toList();
  }

  /// 获取 Channel 成员（包含角色信息）
  Future<List<ChannelMember>> getChannelMembers(String channelId) async {
    final db = await database;
    final results = await db.query(
      'channel_members',
      columns: ['agent_id', 'role', 'group_bio', 'joined_at'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    return results.map((r) => ChannelMember(
      id: r['agent_id'] as String,
      type: 'agent',
      role: r['role'] as String? ?? 'member',
      groupBio: r['group_bio'] as String?,
      joinedAt: DateTime.tryParse(r['joined_at'] as String? ?? '')
              ?.millisecondsSinceEpoch ?? 0,
    )).toList();
  }

  Channel _channelFromMap(Map<String, dynamic> map, List<ChannelMember> members) {
    return Channel(
      id: map['id'],
      name: map['name'],
      description: map['description'],
      type: map['type'],
      avatar: map['avatar_path'],
      members: members,
      isPrivate: map['is_private'] == 1,
      lastMessage: null,
      lastMessageTime: null,
      unreadCount: 0,
      parentGroupId: map['parent_group_id'] as String?,
      systemPrompt: map['system_prompt'] as String?,
      maxLoopRounds: map['max_loop_rounds'] as int?,
      mentionMode: map['mention_mode'] as String?,
      planningMode: (map['planning_mode'] as int?) == 1,
      flowMode: (map['flow_mode'] as int?) == 1,
    );
  }

  /// 获取某 user 和 agent 之间最近活跃的 channel（按最新消息时间排序）
  Future<String?> getLatestActiveChannelForUserAndAgent(String userId, String agentId) async {
    final db = await database;
    // 查找同时包含 userId 和 agentId 的 dm channel，按最近访问时间排序
    final results = await db.rawQuery('''
      SELECT c.id FROM channels c
      INNER JOIN channel_members cm1 ON c.id = cm1.channel_id AND cm1.agent_id = ?
      INNER JOIN channel_members cm2 ON c.id = cm2.channel_id AND cm2.agent_id = ?
      WHERE c.type = 'dm'
      ORDER BY c.updated_at DESC
      LIMIT 1
    ''', [userId, agentId]);

    if (results.isEmpty) return null;
    return results.first['id'] as String;
  }

  /// 获取某个群聊的所有会话（包括原始群聊和所有子会话）
  Future<List<Channel>> getGroupSessions(String parentGroupId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.* FROM channels c
      WHERE c.type = 'group' AND (c.id = ? OR c.parent_group_id = ?)
      ORDER BY c.created_at DESC
    ''', [parentGroupId, parentGroupId]);

    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 获取某个群聊家族中最近活跃的会话（按 updated_at 排序）
  Future<String?> getLatestActiveGroupChannel(String parentGroupId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.id FROM channels c
      WHERE c.type = 'group' AND (c.id = ? OR c.parent_group_id = ?)
      ORDER BY c.updated_at DESC
      LIMIT 1
    ''', [parentGroupId, parentGroupId]);

    if (results.isEmpty) return null;
    return results.first['id'] as String;
  }

  /// 获取某 agent 参与的所有 dm 类型 channels
  Future<List<Channel>> getChannelsForAgent(String agentId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.* FROM channels c
      INNER JOIN channel_members cm ON c.id = cm.channel_id
      WHERE cm.agent_id = ? AND c.type = 'dm'
      ORDER BY c.updated_at DESC
    ''', [agentId]);

    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 获取 channel 最新一条消息（用于会话列表预览）
  Future<Map<String, dynamic>?> getLatestChannelMessage(String channelId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 获取 channel 未读消息数（仅统计 agent 发送的未读消息）
  Future<int> getUnreadCountByChannel(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE channel_id = ? AND is_read = 0 AND sender_type != ?',
      [channelId, 'user'],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  /// 标记 channel 所有消息为已读
  Future<void> markChannelMessagesAsRead(String channelId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_read': 1},
      where: 'channel_id = ? AND is_read = 0',
      whereArgs: [channelId],
    );
  }

  // ==================== 消息操作 ====================

  /// 创建消息
  Future<void> createMessage({
    required String id,
    required String channelId,
    required String senderId,
    required String senderType,
    required String senderName,
    required String content,
    String messageType = 'text',
    Map<String, dynamic>? metadata,
    String? replyToId,
  }) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'id': id,
        'channel_id': channelId,
        'sender_id': senderId,
        'sender_type': senderType,
        'sender_name': senderName,
        'content': content,
        'message_type': messageType,
        'metadata': metadata != null ? jsonEncode(metadata) : null,
        'reply_to_id': replyToId,
        'created_at': DateTime.now().toIso8601String(),
        'is_read': 0,
      },
    );
  }

  /// 获取 Channel 的消息
  Future<List<Map<String, dynamic>>> getChannelMessages(String channelId, {int limit = 100, int offset = 0}) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// 根据 ID 获取单条消息
  Future<Map<String, dynamic>?> getMessageById(String messageId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    return results.isEmpty ? null : results.first;
  }

  /// 标记消息为已读
  Future<void> markMessageAsRead(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 删除消息
  Future<void> deleteMessage(String messageId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 获取消息的 created_at 值
  Future<String?> getMessageCreatedAt(String messageId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      columns: ['created_at'],
      where: 'id = ?',
      whereArgs: [messageId],
    );
    return results.isEmpty ? null : results.first['created_at'] as String?;
  }

  /// 删除指定 channel 中某个时间戳及之后的所有消息
  Future<void> deleteMessagesFromTimestamp(String channelId, String createdAt) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'channel_id = ? AND created_at >= ?',
      whereArgs: [channelId, createdAt],
    );
  }

  /// 获取 Channel 中文本消息的总数
  Future<int> getChannelMessageCount(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM messages WHERE channel_id = ? AND message_type = 'text'",
      [channelId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 删除 Channel 的所有消息
  Future<void> deleteChannelMessages(String channelId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
  }

  /// 更新消息内容
  Future<void> updateMessage({
    required String messageId,
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    final updateData = <String, dynamic>{
      'content': content,
    };

    if (metadata != null) {
      updateData['metadata'] = jsonEncode(metadata);
    }

    await db.update(
      'messages',
      updateData,
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> updateMessageMetadata(String messageId, Map<String, dynamic> metadata) async {
    final db = await database;
    await db.update(
      'messages',
      {'metadata': jsonEncode(metadata)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  // ==================== RemoteAgent 操作 ====================

  /// 创建远端助手
  Future<void> createRemoteAgent(remote_agent.RemoteAgent agent) async {
    final db = await database;
    await db.insert(
      'agents',
      agent.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// 获取所有远端助手
  Future<List<remote_agent.RemoteAgent>> getAllRemoteAgents() async {
    final db = await database;
    final results = await db.query('agents', orderBy: 'is_pinned DESC, created_at DESC');
    return results.map((map) => remote_agent.RemoteAgent.fromMap(map)).toList();
  }

  /// 根据 ID 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentById(String id) async {
    final db = await database;
    final results = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
  }

  /// 根据 Token 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByToken(String token) async {
    final db = await database;
    final results = await db.query('agents', where: 'token = ?', whereArgs: [token]);
    return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
  }

  /// 根据 Endpoint 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByEndpoint(String endpoint) async {
    final db = await database;
    final results = await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
    return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
  }

  /// 获取所有在线的远端助手
  Future<List<remote_agent.RemoteAgent>> getOnlineRemoteAgents() async {
    final db = await database;
    final results = await db.query(
      'agents',
      where: 'status = ?',
      whereArgs: ['online'],
      orderBy: 'connected_at DESC',
    );
    return results.map((map) => remote_agent.RemoteAgent.fromMap(map)).toList();
  }

  /// 更新远端助手
  Future<void> updateRemoteAgent(remote_agent.RemoteAgent agent) async {
    final db = await database;
    await db.update(
      'agents',
      agent.toMap(),
      where: 'id = ?',
      whereArgs: [agent.id],
    );
  }

  /// 更新远端助手状态
  Future<void> updateRemoteAgentStatus(String agentId, String status, {int? connectedAt}) async {
    final db = await database;
    final updateData = {
      'status': status,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };

    if (connectedAt != null) {
      updateData['connected_at'] = connectedAt;
    }

    await db.update(
      'agents',
      updateData,
      where: 'id = ?',
      whereArgs: [agentId],
    );
  }

  /// 更新远端助手心跳
  Future<void> updateRemoteAgentHeartbeat(String agentId) async {
    final db = await database;
    await db.update(
      'agents',
      {
        'last_heartbeat': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [agentId],
    );
  }

  /// 删除远端助手
  Future<void> deleteRemoteAgent(String id) async {
    final db = await database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }

  // ==================== 资源文件操作 ====================

  /// 创建资源记录
  Future<void> createResource({
    required String id,
    required String name,
    required String filePath,
    required String fileType,
    required int fileSize,
    String? mimeType,
    String? thumbnailPath,
    required String ownerId,
    required String ownerType,
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    await db.insert(
      'resources',
      {
        'id': id,
        'name': name,
        'file_path': filePath,
        'file_type': fileType,
        'file_size': fileSize,
        'mime_type': mimeType,
        'thumbnail_path': thumbnailPath,
        'owner_id': ownerId,
        'owner_type': ownerType,
        'created_at': DateTime.now().toIso8601String(),
        'metadata': metadata != null ? jsonEncode(metadata) : null,
      },
    );
  }

  /// 根据 Owner 获取资源
  Future<List<Map<String, dynamic>>> getResourcesByOwner(String ownerId, String ownerType) async {
    final db = await database;
    return await db.query(
      'resources',
      where: 'owner_id = ? AND owner_type = ?',
      whereArgs: [ownerId, ownerType],
      orderBy: 'created_at DESC',
    );
  }

  /// 删除资源记录
  Future<void> deleteResource(String id) async {
    final db = await database;
    await db.delete('resources', where: 'id = ?', whereArgs: [id]);
  }

  // ==================== 数据库维护 ====================

  /// 清空所有数据（用于测试或重置）
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('user');
    await db.delete('agents');
    await db.delete('channels');
    await db.delete('channel_members');
    await db.delete('messages');
    await db.delete('conversation_requests');
    await db.delete('resources');
  }

  /// 关闭数据库
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  // ==================== 工具配置 CRUD ====================

  /// 插入或更新工具配置（upsert）
  Future<void> upsertToolConfig(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'tool_configs',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 查询单个工具配置
  Future<Map<String, dynamic>?> queryToolConfig(String toolName) async {
    final db = await database;
    final results = await db.query(
      'tool_configs',
      where: 'tool_name = ?',
      whereArgs: [toolName],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 查询所有工具配置
  Future<List<Map<String, dynamic>>> queryAllToolConfigs() async {
    final db = await database;
    return db.query('tool_configs', orderBy: 'tool_name ASC');
  }

  /// 删除工具配置
  Future<void> deleteToolConfig(String toolName) async {
    final db = await database;
    await db.delete(
      'tool_configs',
      where: 'tool_name = ?',
      whereArgs: [toolName],
    );
  }

  // ==================== CLI 命令配置 CRUD ====================

  /// 插入或更新 CLI 命令配置（upsert）
  Future<void> upsertCliCommandConfig(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'cli_command_configs',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 查询单个 CLI 命令配置
  Future<Map<String, dynamic>?> queryCliCommandConfig(String commandId) async {
    final db = await database;
    final results = await db.query(
      'cli_command_configs',
      where: 'command_id = ?',
      whereArgs: [commandId],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 查询所有 CLI 命令配置
  Future<List<Map<String, dynamic>>> queryAllCliCommandConfigs() async {
    final db = await database;
    return db.query('cli_command_configs', orderBy: 'command_id ASC');
  }

  /// 删除 CLI 命令配置
  Future<void> deleteCliCommandConfig(String commandId) async {
    final db = await database;
    await db.delete(
      'cli_command_configs',
      where: 'command_id = ?',
      whereArgs: [commandId],
    );
  }

  // ==================== 数据重置 ====================

  /// 关闭并删除所有 DB 文件（重置密码时调用）
  ///
  /// 调用此方法后，所有数据库单例的 `_database` 将被置 null，
  /// 下次访问时会重新创建空白数据库。
  ///
  /// 注意：调用前应已通过 [VaultService.createVault] 完成数据备份。
  static Future<void> clearAllDatabases() async {
    if (kIsWeb) return;

    final dbDir = (await getApplicationDocumentsDirectory()).path;

    // 1. 关闭所有数据库连接（将各 DB 服务的 _database 置 null）
    await LocalDatabaseService().close();
    await SheProfileDatabaseService().close();
    await SheMemoryDbService.instance.close();
    await MindsDatabaseService().close();
    await AgentMemoryDbService.closeAll();

    // 2. 删除核心 DB 文件
    const coreNames = [
      'shepaw.db',
      'she_profile.db',
      'she_memory.db',
      'minds.db',
    ];
    for (final name in coreNames) {
      final file = File(join(dbDir, name));
      if (await file.exists()) {
        await file.delete();
      }
    }

    // 3. 删除所有 agent_memory_*.db 文件
    final dir = Directory(dbDir);
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = basename(entity.path);
        if (name.startsWith('agent_memory_') && name.endsWith('.db')) {
          await entity.delete();
        }
      }
    }
  }

  // ==================== 定时任务操作 ====================

  /// 创建定时任务
  Future<void> createScheduledTask(ScheduledTask task) async {
    final db = await database;
    await db.insert(
      'scheduled_tasks',
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 根据 ID 获取定时任务
  Future<ScheduledTask?> getScheduledTaskById(String id) async {
    final db = await database;
    final results = await db.query(
      'scheduled_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
    return results.isEmpty ? null : ScheduledTask.fromJson(results.first);
  }

  /// 列出定时任务（支持筛选）
  Future<List<ScheduledTask>> listScheduledTasks({
    String? agentId,
    String? status,
    String? channelId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (agentId != null) {
      where.add('agent_id = ?');
      args.add(agentId);
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    if (channelId != null) {
      where.add('channel_id = ?');
      args.add(channelId);
    }

    final results = await db.query(
      'scheduled_tasks',
      where: where.isNotEmpty ? where.join(' AND ') : null,
      whereArgs: args.isNotEmpty ? args : null,
      orderBy: 'next_run_at ASC',
    );

    return results.map((r) => ScheduledTask.fromJson(r)).toList();
  }

  /// 获取到期执行的定时任务
  Future<List<ScheduledTask>> getTasksDueForExecution({int? beforeTime}) async {
    final db = await database;
    final now = beforeTime ?? DateTime.now().millisecondsSinceEpoch;

    final results = await db.query(
      'scheduled_tasks',
      where: 'status = ? AND next_run_at <= ?',
      whereArgs: [ScheduledTask.statusActive, now],
      orderBy: 'next_run_at ASC',
    );

    return results.map((r) => ScheduledTask.fromJson(r)).toList();
  }

  /// 更新定时任务
  Future<void> updateScheduledTask(ScheduledTask task) async {
    final db = await database;
    await db.update(
      'scheduled_tasks',
      task.toJson(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  /// 删除定时任务
  Future<void> deleteScheduledTask(String id) async {
    final db = await database;
    await db.delete(
      'scheduled_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

}