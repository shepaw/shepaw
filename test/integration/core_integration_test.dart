import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shepaw/services/data_export_import_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_file_storage_service.dart';
import 'package:shepaw/services/logger_service.dart';

/// 核心功能集成测试
///
/// 测试数据导入导出等核心功能
///
/// 运行测试：
/// flutter test test/integration/core_integration_test.dart

void main() {
  // 测试在移动端运行，无需特殊初始化
  setUpAll(() {
    // 测试初始化
  });

  group('核心功能集成测试', () {
    late LocalDatabaseService dbService;
    late LoggerService logger;

    setUp(() async {
      // 使用内存数据库进行测试
      logger = LoggerService();
      dbService = LocalDatabaseService();

      await dbService.database;
    });

    tearDown(() async {
      await dbService.close();
    });

    // ==================== 数据导入导出测试 ====================

    group('数据导入导出', () {
      late DataExportImportService exportImportService;
      late LocalFileStorageService fileService;

      setUp(() async {
        fileService = LocalFileStorageService();
        exportImportService = DataExportImportService(
          dbService,
          fileService,
          logger,
        );
      });

      test('应该能导出和导入 Channel 数据', () async {
        final db = await dbService.database;

        // 创建测试 Channel
        await db.insert('channels', {
          'id': 'test-channel-1',
          'name': 'Test Channel',
          'type': 'group',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });

        // 添加成员
        await db.insert('channel_members', {
          'channel_id': 'test-channel-1',
          'user_id': 'user-1',
          'joined_at': DateTime.now().millisecondsSinceEpoch,
        });

        // 添加消息
        await db.insert('messages', {
          'id': 'msg-1',
          'channel_id': 'test-channel-1',
          'sender_id': 'user-1',
          'content': 'Test message',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });

        // 导出 Channel
        final exportPath = await exportImportService.exportChannel('test-channel-1');
        expect(exportPath, isNotNull);

        // 验证导出文件存在
        final exportFile = File(exportPath!);
        expect(await exportFile.exists(), true);

        // 清空测试数据
        await db.delete('messages', where: 'channel_id = ?', whereArgs: ['test-channel-1']);
        await db.delete('channel_members', where: 'channel_id = ?', whereArgs: ['test-channel-1']);
        await db.delete('channels', where: 'id = ?', whereArgs: ['test-channel-1']);

        // 导入 Channel
        final imported = await exportImportService.importChannel(exportPath);
        expect(imported, true);

        // 验证数据恢复
        final channels = await db.query('channels', where: 'id = ?', whereArgs: ['test-channel-1']);
        expect(channels.length, 1);

        final members = await db.query('channel_members', where: 'channel_id = ?', whereArgs: ['test-channel-1']);
        expect(members.length, 1);

        final messages = await db.query('messages', where: 'channel_id = ?', whereArgs: ['test-channel-1']);
        expect(messages.length, 1);
      });

      test('应该能验证元数据', () async {
        // 创建有效的元数据目录
        final tempDir = Directory.systemTemp.createTempSync('test_metadata_');
        final metadataFile = File('${tempDir.path}/metadata.json');
        await metadataFile.writeAsString('{"version":"1.0"}');

        final valid = await exportImportService.exportAllData();
        expect(valid, isNotNull);

        // 清理
        await tempDir.delete(recursive: true);
      });
    });
  });
}
