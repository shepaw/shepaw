@Tags(['needs-plugins'])
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/workflow/workflow_create_command.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/workflow/workflow_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// workflow create 在 DM 频道的创建链路（She 私聊自规划）。
/// Needs path_provider + sqflite harness; excluded from default CI via `needs-plugins`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // path_provider 平台通道 mock：LocalDatabaseService 依赖
    // getApplicationDocumentsDirectory()，无插件环境下会 MissingPluginException。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '/tmp/shepaw_test');
  });

  group('workflow create in DM channel', () {
    setUp(() async {
      await LocalDatabaseService().database;
    });

    test('returns pending_approval with plan data and persists steps', () async {
      final channelId = 'dm-she-user-${DateTime.now().microsecondsSinceEpoch}';
      final result = await WorkflowCreateCommand().execute({
        'title': '调研并总结',
        'summary': '分两阶段完成',
        'channel_id': channelId,
        'stages':
            '[{"label":"调研","steps":[{"agent":"She","instruction":"收集资料"}]},'
            '{"label":"总结","steps":[{"agent":"She","instruction":"输出报告"}]}]',
      });

      expect(result['error'], isNull);
      expect(result['status'], 'pending_approval');
      expect(result['workflow_id'], isNotNull);
      expect(result['total_stages'], 2);
      expect(result['total_steps'], 2);
      expect(result['_plan_data'], isA<Map<String, dynamic>>());

      // DB 读回：频道 id、状态与步骤结构正确（DM channelId 无需频道行存在）。
      final workflowId = result['workflow_id'] as String;
      final loaded = await WorkflowService.instance
          .getWorkflowExecutionWithSteps(workflowId);
      expect(loaded, isNotNull);
      expect(loaded!.channelId, channelId);
      expect(loaded.status, WorkflowStatus.pendingApproval);
      expect(loaded.steps.length, 2);
      expect(loaded.steps[0].stageIndex, 0);
      expect(loaded.steps[1].stageIndex, 1);
      expect(loaded.steps.every((s) => s.agentName == 'She'), true);
      expect(
        loaded.steps.every((s) => s.status == StepExecutionStatus.pending),
        true,
      );
    });
  });
}
