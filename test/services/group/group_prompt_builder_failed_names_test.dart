import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  const builder = GroupPromptBuilder();
  final admin = _agent('admin', 'PM');
  final coder = _agent('coder', 'Coder');

  test('loop summarize prompt includes failedAgentNames', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
      isLoopSummarize: true,
      loopRound: 2,
      failedAgentNames: const ['Coder'],
    );

    expect(prompt, contains('以下成员执行失败：Coder'));
    expect(prompt, contains('不得宣称全部完成'));
  });

  test('loop summarize prompt omits failure clause when nobody failed',
      () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
      isLoopSummarize: true,
      loopRound: 2,
    );

    expect(prompt, isNot(contains('以下成员执行失败')));
  });

  test('initial admin prompt instructs requirement clarification', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
    );

    expect(prompt, contains('需求澄清'));
    expect(prompt, contains('group_finish'));
    expect(prompt, contains('pause'));
    expect(prompt, contains('凭猜测直接派活'));
  });
}
