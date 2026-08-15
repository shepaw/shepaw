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

  test('loop summarize prompt includes failedAgentNames', () {
    final prompt = builder.buildGroupSystemPrompt(
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

  test('loop summarize prompt omits failure clause when nobody failed', () {
    final prompt = builder.buildGroupSystemPrompt(
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
}
