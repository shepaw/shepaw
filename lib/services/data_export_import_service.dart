import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:archive/archive_io.dart';
import 'package:sqflite/sqflite.dart';
import '../services/local_database_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/logger_service.dart';
import '../services/she_memory_db_service.dart';
import '../services/minds_database_service.dart';
import '../services/agent_memory_db_service.dart';
import '../services/agent_memory_store_service.dart';
import '../models/cognition.dart';
import '../models/agent_memory_entry.dart';
import '../storage/device_identity.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 数据导入导出服务
/// 
/// P2: 支持数据备份、恢复和迁移
class DataExportImportService {
  final LocalDatabaseService _dbService;
  final LocalFileStorageService _fileService;
  final LoggerService _logger;

  DataExportImportService(
    this._dbService,
    this._fileService,
    this._logger,
  );

  /// 导出所有数据
  /// 
  /// 创建一个包含数据库和文件的完整备份
  Future<String?> exportAllData({
    bool includeFiles = true,
    bool includeSettings = true,
  }) async {
    try {
      _logger.info('Starting full data export');
      
      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory('${tempDir.path}/export_${DateTime.now().millisecondsSinceEpoch}');
      await exportDir.create(recursive: true);

      // 1. 导出数据库数据
      await _exportDatabaseData(exportDir);

      // 2. 导出文件
      if (includeFiles) {
        await _exportFiles(exportDir);
      }

      // 3. 导出设置
      if (includeSettings) {
        await _exportSettings(exportDir);
      }

      // 4. 创建元数据文件
      await _createMetadata(exportDir);

      // 5. 压缩为 ZIP 文件
      final zipPath = await _createZipArchive(exportDir);

      // 6. 清理临时目录
      await exportDir.delete(recursive: true);

      _logger.info('Data export completed: $zipPath');
      return zipPath;
    } catch (e, stackTrace) {
      _logger.error('Data export failed', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  /// 导入数据
  Future<bool> importData(String zipPath, {
    bool overwriteExisting = false,
  }) async {
    try {
      _logger.info('Starting data import from: $zipPath');

      final tempDir = await getTemporaryDirectory();
      final importDir = Directory('${tempDir.path}/import_${DateTime.now().millisecondsSinceEpoch}');
      await importDir.create(recursive: true);

      // 1. 解压 ZIP 文件
      await _extractZipArchive(zipPath, importDir);

      // 2. 验证元数据
      final valid = await _validateMetadata(importDir);
      if (!valid) {
        throw Exception('Invalid export file');
      }

      // 3. 导入数据库数据
      await _importDatabaseData(importDir, overwriteExisting);

      // 4. 导入文件
      await _importFiles(importDir, overwriteExisting);

      // 5. 导入设置
      await _importSettings(importDir);

      // 6. 清理临时目录
      await importDir.delete(recursive: true);

      _logger.info('Data import completed successfully');
      return true;
    } catch (e, stackTrace) {
      _logger.error('Data import failed', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  /// 导出特定 Channel 的数据
  Future<String?> exportChannel(String channelId) async {
    try {
      _logger.info('Exporting channel: $channelId');

      final db = await _dbService.database;
      
      // 获取 Channel 信息
      final channelData = await db.query(
        'channels',
        where: 'id = ?',
        whereArgs: [channelId],
      );

      if (channelData.isEmpty) {
        throw Exception('Channel not found');
      }

      // 获取消息
      final messages = await db.query(
        'messages',
        where: 'channel_id = ?',
        whereArgs: [channelId],
        orderBy: 'created_at ASC',
      );

      // 获取成员
      final members = await db.query(
        'channel_members',
        where: 'channel_id = ?',
        whereArgs: [channelId],
      );

      final exportData = {
        'version': '1.0',
        'exportType': 'channel',
        'timestamp': DateTime.now().toIso8601String(),
        'channel': channelData.first,
        'members': members,
        'messages': messages,
      };

      final tempDir = await getTemporaryDirectory();
      final exportFile = File('${tempDir.path}/channel_$channelId.json');
      await exportFile.writeAsString(json.encode(exportData));

      _logger.info('Channel export completed');
      return exportFile.path;
    } catch (e, stackTrace) {
      _logger.error('Channel export failed', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  /// 导入 Channel 数据
  Future<bool> importChannel(String jsonPath) async {
    try {
      _logger.info('Importing channel from: $jsonPath');

      final file = File(jsonPath);
      final content = await file.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;

      if (data['exportType'] != 'channel') {
        throw Exception('Invalid channel export file');
      }

      final db = await _dbService.database;

      // 导入 Channel
      await db.insert('channels', data['channel']);

      // 导入成员
      for (final member in data['members'] as List) {
        await db.insert('channel_members', member);
      }

      // 导入消息
      for (final message in data['messages'] as List) {
        await db.insert('messages', message);
      }

      _logger.info('Channel import completed');
      return true;
    } catch (e, stackTrace) {
      _logger.error('Channel import failed', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  // ==================== 私有方法 ====================

  Future<void> _exportDatabaseData(Directory exportDir) async {
    final dataDir = Directory('${exportDir.path}/data');
    await dataDir.create();

    final db = await _dbService.database;
    final tables = [
      'users', 'agents', 'channels', 'channel_members', 'messages',
      'conversation_requests', 'resources', 'agent_cards', 'tasks'
    ];

    for (final table in tables) {
      try {
        final data = await db.query(table);
        final file = File('${dataDir.path}/$table.json');
        await file.writeAsString(json.encode(data));
        _logger.debug('Exported table: $table');
      } catch (e) {
        _logger.warning('Failed to export table $table', error: e);
      }
    }

    await _exportMemoryData(dataDir);
  }

  /// 导出记忆数据：She 的记忆 KV、minds.db 认知、各 Agent 独立记忆库。
  ///
  /// 与主库表导出相同的 JSON 文件风格；每类数据独立 try/catch，
  /// 单项失败不影响整体备份。
  Future<void> _exportMemoryData(Directory dataDir) async {
    // She 的记忆 KV（soul / long_term_memory / heartbeat 等）
    try {
      final sheMemory = await SheMemoryDbService().getAllSheMemory();
      await File('${dataDir.path}/she_memory.json')
          .writeAsString(json.encode(sheMemory));
      _logger.debug('Exported she_memory');
    } catch (e) {
      _logger.warning('Failed to export she_memory', error: e);
    }

    // minds.db：各 Agent 的自我认知 + 用户认知（含 user_profile）
    try {
      final minds = MindsDatabaseService();
      final selfCogs = await minds.getAllSelfCognitions();
      await File('${dataDir.path}/cognition_self.json').writeAsString(
          json.encode(selfCogs.map((c) => c.toMap()).toList()));
      final userCogs = await minds.getAllUserCognitions();
      await File('${dataDir.path}/cognition_user.json').writeAsString(
          json.encode(userCogs.map((c) => c.toMap()).toList()));
      _logger.debug('Exported minds.db cognitions');
    } catch (e) {
      _logger.warning('Failed to export cognitions', error: e);
    }

    // Agent 记忆：权威在储物袋 memory/；兼扫遗留 agent_memory_*.db
    try {
      final memDir = Directory('${dataDir.path}/agent_memory');
      await memDir.create(recursive: true);
      final exported = <String>{};

      try {
        final deviceId = await DeviceIdentity.deviceId();
        final store = await StoreService.instance.localStore();
        final roots = await store.list(
          deviceId,
          StoreSpace.memory,
          depth: 1,
          limit: 5000,
        );
        for (final e in roots) {
          if (!e.isDir) continue;
          final agentId = e.path;
          final memories = await AgentMemoryStoreService.forAgent(agentId)
              .getAllMemories(limit: 100000);
          if (memories.isEmpty) continue;
          await File('${memDir.path}/$agentId.json').writeAsString(
              json.encode(memories.map((m) => m.toMap()).toList()));
          exported.add(agentId);
        }
      } catch (e) {
        _logger.warning('store memory export partial fail: $e');
      }

      final docsDir = await getApplicationDocumentsDirectory();
      await for (final entity in docsDir.list()) {
        final name = entity.path.split('/').last;
        if (entity is! File ||
            !name.startsWith('agent_memory_') ||
            !name.endsWith('.db')) {
          continue;
        }
        final agentId = name.substring('agent_memory_'.length, name.length - 3);
        if (exported.contains(agentId)) continue;
        final memories = await AgentMemoryDbService.forAgent(agentId)
            .getAllMemories(limit: 100000);
        if (memories.isEmpty) continue;
        await File('${memDir.path}/$agentId.json').writeAsString(
            json.encode(memories.map((m) => m.toMap()).toList()));
      }
      _logger.debug('Exported agent memories');
    } catch (e) {
      _logger.warning('Failed to export agent memories', error: e);
    }
  }

  Future<void> _exportFiles(Directory exportDir) async {
    final filesDir = Directory('${exportDir.path}/files');
    await filesDir.create();

    final storageDir = await _fileService.getStorageDirectory();
    if (await storageDir.exists()) {
      await _copyDirectory(storageDir, filesDir);
      _logger.debug('Exported files');
    }
  }

  Future<void> _exportSettings(Directory exportDir) async {
    final settings = {
      'theme': 'system',
      'notifications': true,
      'version': '1.0.0',
    };

    final file = File('${exportDir.path}/settings.json');
    await file.writeAsString(json.encode(settings));
  }

  Future<void> _createMetadata(Directory exportDir) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final metadata = {
      'version': '1.0',
      'exportedAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'appVersion': packageInfo.version,
    };

    final file = File('${exportDir.path}/metadata.json');
    await file.writeAsString(json.encode(metadata));
  }

  Future<String> _createZipArchive(Directory sourceDir) async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final zipPath = '${tempDir.path}/shepaw_backup_$timestamp.zip';

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    await encoder.addDirectory(sourceDir);
    encoder.close();

    return zipPath;
  }

  Future<void> _extractZipArchive(String zipPath, Directory targetDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final file in archive) {
      final filename = '${targetDir.path}/${file.name}';
      if (file.isFile) {
        final outFile = File(filename);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filename).create(recursive: true);
      }
    }
  }

  Future<bool> _validateMetadata(Directory importDir) async {
    try {
      final file = File('${importDir.path}/metadata.json');
      if (!await file.exists()) return false;

      final content = await file.readAsString();
      final metadata = json.decode(content) as Map<String, dynamic>;

      return metadata['version'] == '1.0';
    } catch (e) {
      return false;
    }
  }

  Future<void> _importDatabaseData(Directory importDir, bool overwrite) async {
    final dataDir = Directory('${importDir.path}/data');
    if (!await dataDir.exists()) return;

    final db = await _dbService.database;
    final files = await dataDir.list().toList();

    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.json')) {
        final tableName = entity.path.split('/').last.replaceAll('.json', '');
        try {
          final content = await entity.readAsString();
          final data = json.decode(content) as List;

          for (final row in data) {
            if (overwrite) {
              await db.insert(
                tableName,
                row,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            } else {
              await db.insert(
                tableName,
                row,
                conflictAlgorithm: ConflictAlgorithm.ignore,
              );
            }
          }
          _logger.debug('Imported table: $tableName');
        } catch (e) {
          _logger.warning('Failed to import table $tableName', error: e);
        }
      }
    }

    await _importMemoryData(dataDir, overwrite);
  }

  /// 导入记忆数据（对应 [_exportMemoryData]；文件缺失时静默跳过，
  /// 因此旧版本备份仍可正常导入）。
  ///
  /// [overwrite] 为 false 时：已存在的 She 记忆 key、已存在的认知行、
  /// 以及非空的 Agent 记忆库会被跳过，避免覆盖现有数据。
  Future<void> _importMemoryData(Directory dataDir, bool overwrite) async {
    // She 的记忆 KV
    try {
      final file = File('${dataDir.path}/she_memory.json');
      if (await file.exists()) {
        final map =
            (json.decode(await file.readAsString()) as Map).cast<String, dynamic>();
        final sheMemDb = SheMemoryDbService();
        for (final entry in map.entries) {
          final value = entry.value?.toString();
          if (value == null) continue;
          if (overwrite || await sheMemDb.getSheMemory(entry.key) == null) {
            await sheMemDb.setSheMemory(entry.key, value);
          }
        }
        _logger.debug('Imported she_memory');
      }
    } catch (e) {
      _logger.warning('Failed to import she_memory', error: e);
    }

    // minds.db 认知
    try {
      final minds = MindsDatabaseService();
      final selfFile = File('${dataDir.path}/cognition_self.json');
      if (await selfFile.exists()) {
        for (final raw in json.decode(await selfFile.readAsString()) as List) {
          final cog =
              SelfCognition.fromMap((raw as Map).cast<String, dynamic>());
          if (overwrite || await minds.getSelfCognition(cog.agentId) == null) {
            await minds.setSelfCognition(cog);
          }
        }
      }
      final userFile = File('${dataDir.path}/cognition_user.json');
      if (await userFile.exists()) {
        for (final raw in json.decode(await userFile.readAsString()) as List) {
          final cog =
              UserCognition.fromMap((raw as Map).cast<String, dynamic>());
          if (overwrite || await minds.getUserCognition(cog.agentId) == null) {
            await minds.setUserCognition(cog);
          }
        }
      }
      _logger.debug('Imported minds.db cognitions');
    } catch (e) {
      _logger.warning('Failed to import cognitions', error: e);
    }

    // Agent 记忆 → 储物袋 memory/（memory_id 随备份保留）
    try {
      final memDir = Directory('${dataDir.path}/agent_memory');
      if (await memDir.exists()) {
        await for (final entity in memDir.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          final agentId = entity.path.split('/').last.replaceAll('.json', '');
          final service = AgentMemoryStoreService.forAgent(agentId);
          if (!overwrite && await service.getMemoryCount() > 0) continue;
          if (overwrite) await service.clearAllMemories();
          final list = json.decode(await entity.readAsString()) as List;
          for (final raw in list) {
            final map = (raw as Map).cast<String, dynamic>();
            await service.importEntry(AgentMemoryEntry.fromMap(map));
          }
        }
        _logger.debug('Imported agent memories');
      }
    } catch (e) {
      _logger.warning('Failed to import agent memories', error: e);
    }
  }

  Future<void> _importFiles(Directory importDir, bool overwrite) async {
    final filesDir = Directory('${importDir.path}/files');
    if (!await filesDir.exists()) return;

    final storageDir = await _fileService.getStorageDirectory();
    await _copyDirectory(filesDir, storageDir, overwrite: overwrite);
    _logger.debug('Imported files');
  }

  Future<void> _importSettings(Directory importDir) async {
    final file = File('${importDir.path}/settings.json');
    if (await file.exists()) {
      _logger.debug('Imported settings');
    }
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination, {
    bool overwrite = false,
  }) async {
    await destination.create(recursive: true);

    await for (final entity in source.list(recursive: false)) {
      if (entity is Directory) {
        final newDirectory = Directory(
          '${destination.path}/${entity.path.split('/').last}',
        );
        await _copyDirectory(entity, newDirectory, overwrite: overwrite);
      } else if (entity is File) {
        final newFile = File(
          '${destination.path}/${entity.path.split('/').last}',
        );
        if (overwrite || !await newFile.exists()) {
          await entity.copy(newFile.path);
        }
      }
    }
  }
}
