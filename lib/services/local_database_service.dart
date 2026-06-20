import 'dart:io' show Platform, File, Directory;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'she_profile_database_service.dart';
import 'she_memory_db_service.dart';
import 'minds_database_service.dart';
import 'agent_memory_db_service.dart';
import 'logger_service.dart';

// 各业务领域的数据访问层（DAO）以 extension 形式拆分到 database/ 目录下，
// 通过 export 重新导出，调用方只需 import 'local_database_service.dart' 即可
// 使用全部方法，无需感知拆分细节。
export 'database/agent_dao.dart';
export 'database/channel_dao.dart';
export 'database/message_dao.dart';
export 'database/remote_agent_dao.dart';
export 'database/config_dao.dart';
export 'database/scheduled_task_dao.dart';
export 'database/identity_dao.dart';
export 'database/sync_dao.dart';

/// 本地数据库服务 - 使用 SQLite 存储所有数据
///
/// 仅保留数据库生命周期与建表/迁移逻辑；各表的 CRUD 已按领域拆分为
/// `database/*_dao.dart` 中的 extension（见上方 export）。
class LocalDatabaseService {
  static final LocalDatabaseService _instance = LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _database;

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
        version: 24,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      // Windows/Linux 使用 sqflite_common_ffi
      final directory = await getApplicationDocumentsDirectory();
      path = join(directory.path, 'shepaw.db');
      return await openDatabase(
        path,
        version: 24,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } else {
      // 移动平台使用sqflite
      final directory = await getApplicationDocumentsDirectory();
      path = join(directory.path, 'shepaw.db');

      return await openDatabase(
        path,
        version: 24,
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

    // 工作流执行记录表 (v22)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_executions (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        title TEXT NOT NULL,
        summary TEXT,
        flow_plan_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending_approval',
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        completed_at INTEGER,
        trigger_message TEXT,
        error_message TEXT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_executions_channel ON workflow_executions(channel_id, created_at DESC)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_executions_status ON workflow_executions(status)');

    // 工作流步骤执行记录表 (v22)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_step_executions (
        id TEXT PRIMARY KEY,
        workflow_execution_id TEXT NOT NULL,
        stage_index INTEGER NOT NULL,
        step_index INTEGER NOT NULL,
        stage_name TEXT DEFAULT '',
        agent_name TEXT NOT NULL,
        instruction TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        started_at INTEGER,
        completed_at INTEGER,
        output_summary TEXT,
        error_message TEXT,
        FOREIGN KEY (workflow_execution_id) REFERENCES workflow_executions(id)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_steps_execution ON workflow_step_executions(workflow_execution_id, stage_index, step_index)');

    await _createIdentityTables(db);
    await _createBlobCacheTable(db);
  }

  static Future<void> _createBlobCacheTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_blob_cache (
        blob_key TEXT PRIMARY KEY,
        relative_path TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        mime_type TEXT,
        cached_at INTEGER NOT NULL,
        last_access_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_blob_cache_access ON identity_blob_cache(last_access_at ASC)');
  }

  static Future<void> _createIdentityTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_user (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL DEFAULT '',
        public_key BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_spirit_pet (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT 'She',
        public_key BLOB NOT NULL,
        agent_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES identity_user(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_owned_devices (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL UNIQUE,
        device_name TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'app',
        transport_public_key BLOB NOT NULL,
        fingerprint TEXT NOT NULL,
        user_id TEXT NOT NULL,
        pet_id TEXT NOT NULL,
        is_local INTEGER NOT NULL DEFAULT 0,
        trusted_at INTEGER NOT NULL,
        last_seen_at INTEGER
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_owned_devices_user ON identity_owned_devices(user_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_owned_devices_role ON identity_owned_devices(role)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_ownership_bonds (
        pet_id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        owner_fingerprint TEXT NOT NULL,
        bonded_at INTEGER NOT NULL,
        bond_signature BLOB NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_message_index (
        message_id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        wall_time INTEGER NOT NULL,
        preview TEXT NOT NULL,
        sender_name TEXT NOT NULL,
        has_attachment INTEGER NOT NULL DEFAULT 0,
        synced_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_msg_index_channel ON identity_message_index(channel_id, wall_time DESC)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS identity_outbound_queue (
        id TEXT PRIMARY KEY,
        domain TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        acked INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_outbound_pending ON identity_outbound_queue(acked, created_at)');
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

    if (oldVersion < 22) {
      // 版本 21 -> 22: 添加工作流执行记录表
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS workflow_executions (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT,
            flow_plan_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending_approval',
            created_at INTEGER NOT NULL,
            started_at INTEGER,
            completed_at INTEGER,
            trigger_message TEXT,
            error_message TEXT
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_executions_channel ON workflow_executions(channel_id, created_at DESC)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_executions_status ON workflow_executions(status)');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS workflow_step_executions (
            id TEXT PRIMARY KEY,
            workflow_execution_id TEXT NOT NULL,
            stage_index INTEGER NOT NULL,
            step_index INTEGER NOT NULL,
            stage_name TEXT DEFAULT '',
            agent_name TEXT NOT NULL,
            instruction TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            started_at INTEGER,
            completed_at INTEGER,
            output_summary TEXT,
            error_message TEXT,
            FOREIGN KEY (workflow_execution_id) REFERENCES workflow_executions(id)
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_steps_execution ON workflow_step_executions(workflow_execution_id, stage_index, step_index)');
      } catch (e) {
        LoggerService().error('Failed to create workflow tables (v22)', tag: 'Migration', error: e);
      }
    }

    if (oldVersion < 23) {
      try {
        await _createIdentityTables(db);
      } catch (e) {
        LoggerService().error('Failed to create identity tables (v23)', tag: 'Migration', error: e);
      }
    }

    if (oldVersion < 24) {
      try {
        await _createBlobCacheTable(db);
      } catch (e) {
        LoggerService().error('Failed to create blob cache table (v24)', tag: 'Migration', error: e);
      }
    }

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
}
