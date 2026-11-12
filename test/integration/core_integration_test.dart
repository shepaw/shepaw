@Tags(['needs-plugins'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/data_export_import_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_file_storage_service.dart';
import 'package:shepaw/services/logger_service.dart';

import '../storage/test_harness.dart';

/// 核心功能集成测试
///
/// 测试数据导入导出等核心功能
///
/// 运行测试：
/// flutter test test/integration/core_integration_test.dart
///
/// Needs path_provider / filesystem harness; excluded from default CI via `needs-plugins`.

void main() {
  setUpAll(() async {
    // 导出/导入要碰 AppPaths 和 getTemporaryDirectory：统一装平台 harness，
    // 不然本地跑会报 "Binding has not yet been initialized"。
    await StorageTestHarness.init();
    // 打全量备份时 _createMetadata 要读 package_info_plus；无插件环境下
    // 给一份假版本，否则 exportAllData 会吞掉 MissingPluginException 返回 null。
    const packageInfo = MethodChannel('dev.fluttercommunity.plus/package_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfo, (call) async => <String, dynamic>{
              'appName': 'ShePaw Test',
              'packageName': 'com.shepaw.test',
              'version': '1.0.0',
              'buildNumber': '1',
              'buildSignature': '',
            });
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

        // 按当前 schema 补齐 NOT NULL 列（created_at/updated_at 是 TEXT）。
        final now = DateTime.now().millisecondsSinceEpoch.toString();

        // 创建测试 Channel
        await db.insert('channels', {
          'id': 'test-channel-1',
          'name': 'Test Channel',
          'type': 'group',
          'created_at': now,
          'updated_at': now,
          'created_by': 'user-1',
        });

        // 添加成员
        await db.insert('channel_members', {
          'channel_id': 'test-channel-1',
          'agent_id': 'user-1',
          'joined_at': now,
        });

        // 添加消息
        await db.insert('messages', {
          'id': 'msg-1',
          'channel_id': 'test-channel-1',
          'sender_id': 'user-1',
          'sender_type': 'user',
          'sender_name': 'User 1',
          'content': 'Test message',
          'created_at': now,
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
        final zipPath = await exportImportService.exportAllData();
        expect(zipPath, isNotNull, reason: '全量导出不该被平台插件挡住');

        // 包里要有 _validateMetadata 认得的 metadata.json。
        final archive = ZipDecoder()
            .decodeBytes(await File(zipPath!).readAsBytes());
        // ZipFileEncoder.addDirectory 会把外层 export_<ts>/ 一起打进去。
        final metadataFile =
            archive.firstWhere((f) => f.name.endsWith('/metadata.json'));
        final metadata = json.decode(
          utf8.decode(metadataFile.content as List<int>),
        ) as Map<String, dynamic>;
        expect(metadata['version'], '1.0',
            reason: '_validateMetadata 只认 version=1.0');
        expect(metadata['appVersion'], isNotEmpty);
      });
    });
  });
}
