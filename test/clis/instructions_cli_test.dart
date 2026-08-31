import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/instructions/instructions_namespace.dart';
import 'package:shepaw/clis/shepaw/instructions/save_command.dart';
import 'package:shepaw/clis/shepaw/instructions/update_command.dart';
import 'package:shepaw/clis/shepaw/instructions/delete_command.dart';
import 'package:shepaw/clis/shepaw/instructions/run_command.dart';
import 'package:shepaw/services/instruction_set_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  setUp(() async {
    final db = LocalDatabaseService();
    final handle = await db.database;
    await handle.delete('instruction_sets');
  });

  /// 在指定执行者 Zone 中运行 [body]。
  Future<T> asAgent<T>(String agentId, Future<T> Function() body) =>
      ChatAgentScope.runScoped(agentId: agentId, body: body);

  group('instructions namespace', () {
    test('registered and exposes all commands', () async {
      final help = await InstructionsNamespace.instance.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      for (final name in ['save', 'list', 'get', 'update', 'delete', 'run']) {
        expect(commands.containsKey(name), true,
            reason: 'namespace should expose instructions $name');
      }
    });
  });

  group('instructions save', () {
    test('records the calling agent as owner', () async {
      final result = await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': '日报', 'content': '输出今日工作日报'}));
      expect(result['success'], true);
      expect(result['action'], 'created');
      expect(result['owner_agent_id'], 'agent-a');

      final loaded =
          await InstructionSetService.instance.getByName('日报');
      expect(loaded!.ownerAgentId, 'agent-a');
    });

    test('save same name by owner updates instead of creating', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v2'}));
      expect(result['success'], true);
      expect(result['action'], 'updated');

      final list = await InstructionSetService.instance.list();
      final mine = list
          .where((e) => e.name != InstructionSetService.systemInstructionName)
          .toList();
      expect(mine.length, 1);
      expect(mine.first.content, 'v2');
    });

    test('save same name by non-owner is denied', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-b', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v2'}));
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('Permission denied'));
      expect((await InstructionSetService.instance.getByName('x'))!.content,
          'v1');
    });

    test('missing flags return structured errors', () async {
      final missingName =
          await SaveInstructionCommand().execute({'content': 'c'});
      expect(missingName['error'], contains('--name'));
      final missingContent =
          await SaveInstructionCommand().execute({'name': 'n'});
      expect(missingContent['error'], contains('--content'));
    });
  });

  group('instructions update / delete permission', () {
    test('owner can update', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-a', () => UpdateInstructionCommand()
          .execute({'name': 'x', 'content': 'v2'}));
      expect(result['success'], true);
      expect((await InstructionSetService.instance.getByName('x'))!.content,
          'v2');
    });

    test('She can update any instruction', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent(SheService.sheId,
          () => UpdateInstructionCommand().execute({'name': 'x', 'content': 'v2'}));
      expect(result['success'], true);
    });

    test('non-owner agent cannot update', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-b', () => UpdateInstructionCommand()
          .execute({'name': 'x', 'content': 'v2'}));
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('Permission denied'));
    });

    test('non-owner agent cannot delete', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-b', () => DeleteInstructionCommand()
          .execute({'name': 'x'}));
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('Permission denied'));
      expect(await InstructionSetService.instance.getByName('x'), isNotNull);
    });

    test('owner can delete', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'x', 'content': 'v1'}));
      final result = await asAgent('agent-a', () => DeleteInstructionCommand()
          .execute({'name': 'x'}));
      expect(result['success'], true);
      expect(await InstructionSetService.instance.getByName('x'), isNull);
    });
  });

  group('instructions get / list', () {
    test('get returns full content', () async {
      await asAgent('agent-a', () => SaveInstructionCommand().execute(
          {'name': 'y', 'content': 'content-y', 'desc': 'desc-y'}));
      final result = await asAgent('agent-b',
          () => InstructionsNamespace.instance.commands['get']!.execute({
                'name': 'y',
              }));
      expect(result['name'], 'y');
      expect(result['content'], 'content-y');
      expect(result['description'], 'desc-y');
    });

    test('list shows saved instructions', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'y', 'content': 'content-y'}));
      final result = await asAgent('agent-b',
          () => InstructionsNamespace.instance.commands['list']!.execute({}));
      // 内置系统指令「沉淀指令」始终存在，故 count 为 2。
      expect(result['count'], 2);
      final names = (result['instructions'] as List)
          .map((e) => (e as Map)['name'])
          .toList();
      expect(names, contains('y'));
      expect(names, contains(InstructionSetService.systemInstructionName));
    });
  });

  group('instructions run', () {
    test('returns content for direct execution when owner is caller', () async {
      await asAgent('agent-a', () => SaveInstructionCommand()
          .execute({'name': 'task', 'content': 'do the thing'}));
      final result = await asAgent('agent-a',
          () => RunInstructionCommand().execute({'name': 'task'}));
      expect(result['success'], true);
      expect(result['content'], 'do the thing');
    });

    test('returns content for direct execution when owner is She', () async {
      await asAgent(SheService.sheId, () => SaveInstructionCommand()
          .execute({'name': 'task', 'content': 'do the thing'}));
      final result = await asAgent(SheService.sheId,
          () => RunInstructionCommand().execute({'name': 'task'}));
      expect(result['success'], true);
      expect(result['content'], 'do the thing');
    });

    test('unknown instruction returns error', () async {
      final result = await RunInstructionCommand().execute({'name': 'nope'});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('not found'));
    });
  });
}
