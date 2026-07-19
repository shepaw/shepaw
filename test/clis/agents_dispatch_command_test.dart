import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/agents/agents_namespace.dart';
import 'package:shepaw/clis/shepaw/agents/dispatch_command.dart';

/// 覆盖 agents.dispatch 命令中不依赖数据库的路径：
/// 参数校验、help 结构、命名空间注册。
void main() {
  group('agents.dispatch command', () {
    test('registered in agents namespace', () async {
      final ns = AgentsNamespace.instance;
      final help = await ns.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      expect(commands.containsKey('dispatch'), true,
          reason: 'agents namespace should expose the dispatch command');
    });

    test('getHelp exposes flag documentation', () {
      final cmd = DispatchCommand();
      final help = cmd.getHelp();
      expect(help['command'], 'dispatch');
      expect(help['description'], isNotEmpty);
      final flags = help['flags'] as Map<String, dynamic>;
      for (final key in ['id', 'task', 'timeout-min', 'confirm']) {
        expect(flags.containsKey(key), true,
            reason: 'help should document --$key');
      }
      expect((flags['id'] as Map)['required'], true);
      expect((flags['task'] as Map)['required'], true);
    });

    test('missing --id returns structured error without touching DB', () async {
      final cmd = DispatchCommand();
      final result = await cmd.execute({'task': 'do something'});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--id'));
    });

    test('missing --task returns structured error without touching DB', () async {
      final cmd = DispatchCommand();
      final result = await cmd.execute({'id': 'some-agent'});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--task'));
    });
  });
}
