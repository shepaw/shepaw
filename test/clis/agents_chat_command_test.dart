import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/agents/agents_namespace.dart';
import 'package:shepaw/clis/shepaw/agents/chat_command.dart';

/// 覆盖 agents.chat 命令中不依赖数据库的路径：
/// 参数校验、help 结构、命名空间注册。
void main() {
  group('agents.chat command', () {
    test('registered in agents namespace', () async {
      final ns = AgentsNamespace.instance;
      final help = await ns.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      expect(commands.containsKey('chat'), true,
          reason: 'agents namespace should expose the chat command');
    });

    test('getHelp exposes flag documentation', () {
      final cmd = ChatCommand();
      final help = cmd.getHelp();
      expect(help['command'], 'chat');
      expect(help['description'], isNotEmpty);
      final flags = help['flags'] as Map<String, dynamic>;
      for (final key in ['id', 'message', 'channel', 'timeout-min']) {
        expect(flags.containsKey(key), true,
            reason: 'help should document --$key');
      }
      expect((flags['id'] as Map)['required'], true);
      expect((flags['message'] as Map)['required'], true);
    });

    test('description promises automatic reply relay', () {
      final cmd = ChatCommand();
      expect(cmd.description, contains('[Agent Reply]'),
          reason: 'chat 的闭环语义（回复自动回传）应体现在命令描述里，'
              '否则 She 不知道自己会被重新唤起');
    });

    test('missing --id returns structured error without touching DB', () async {
      final cmd = ChatCommand();
      final result = await cmd.execute({'message': 'hello'});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--id'));
    });

    test('missing --message returns structured error without touching DB',
        () async {
      final cmd = ChatCommand();
      final result = await cmd.execute({'id': 'some-agent'});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--message'));
    });
  });
}
