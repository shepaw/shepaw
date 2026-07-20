import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/workflow/workflow_create_command.dart';

/// 覆盖 workflow create 命令中不依赖数据库的路径：参数校验。
/// DM 频道创建链路见 test/services/workflow/workflow_create_command_db_test.dart
/// （@Tags(['needs-plugins'])）。
void main() {
  group('workflow create command validation', () {
    test('missing --title returns structured error', () async {
      final result = await WorkflowCreateCommand().execute({
        'stages': '[{"label":"s","steps":[{"agent":"She","instruction":"do"}]}]',
        'channel_id': 'ch-1',
      });
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--title'));
    });

    test('missing --stages returns structured error', () async {
      final result = await WorkflowCreateCommand().execute({
        'title': 't',
        'channel_id': 'ch-1',
      });
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--stages'));
    });

    test('invalid --stages JSON returns structured error', () async {
      final result = await WorkflowCreateCommand().execute({
        'title': 't',
        'stages': 'not-json',
        'channel_id': 'ch-1',
      });
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('Invalid --stages JSON'));
    });

    test('empty stages array returns structured error', () async {
      final result = await WorkflowCreateCommand().execute({
        'title': 't',
        'stages': '[]',
        'channel_id': 'ch-1',
      });
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('at least one stage'));
    });

    test('missing channel context errors without mentioning group chat', () async {
      // DM 工作流：channel_id 由 paw CLI 执行点自动注入；缺失时报错文案
      // 不应再把命令限制成群聊专属。
      final result = await WorkflowCreateCommand().execute({
        'title': 't',
        'stages': '[{"label":"s","steps":[{"agent":"She","instruction":"do"}]}]',
      });
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('No active channel context'));
      expect(result['error'] as String, isNot(contains('group chat')));
    });
  });
}
