import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';

RemoteAgent _agent(
  String id,
  String name, {
  String? bio,
  List<String> capabilities = const [],
}) =>
    RemoteAgent(
      id: id,
      name: name,
      avatar: '🤖',
      bio: bio,
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
      capabilities: capabilities,
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
    expect(prompt, contains('系统会拦截'));
  });

  test('pending-status nudge prompt forbids group_finish done', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
      isPendingStatusNudge: true,
    );

    expect(prompt, contains('pending'));
    expect(prompt, contains('禁止'));
    expect(prompt, contains('group_finish'));
    expect(prompt, contains('pause'));
  });

  test('member roster is name + one-line role, not soul specialty', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [
        admin,
        _agent('coder', 'Coder',
            bio: '负责后端接口与数据模型', capabilities: const ['python', 'sql']),
      ],
      currentAgent: coder,
      isAdmin: false,
    );

    expect(prompt, contains('- Coder'));
    expect(prompt, contains('职责: 负责后端接口与数据模型'));
    expect(prompt, isNot(contains('专长:')));
    expect(prompt, isNot(contains('能力:')));
    expect(prompt, contains('【成员在线】'));
  });

  test('admin roster is role-first; specialty is on-demand via agents.get',
      () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [
        admin,
        _agent('coder', 'Coder',
            bio: '负责后端接口与数据模型', capabilities: const ['python', 'sql']),
      ],
      currentAgent: admin,
      isAdmin: true,
    );

    expect(prompt, contains('- Coder (`coder`)'));
    expect(prompt, contains('职责: 负责后端接口与数据模型'));
    expect(prompt, contains('agents.get'));
    expect(prompt, isNot(contains('专长:')));
    expect(prompt, isNot(contains('能力: python, sql')));
    expect(prompt, contains('【成员在线】'));
    expect(prompt, isNot(contains('(在线)')));
    expect(prompt, isNot(contains('(离线)')));
  });

  test('loop failure names sit in dynamic suffix, not static cache prefix',
      () async {
    final layered = await builder.buildLayeredGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
      isLoopSummarize: true,
      loopRound: 2,
      failedAgentNames: const ['Coder'],
    );

    expect(layered.staticPrefix, isNot(contains('以下成员执行失败')));
    expect(layered.staticPrefix, isNot(contains('【成员在线】')));
    expect(layered.dynamicSuffix, contains('以下成员执行失败：Coder'));
    expect(layered.dynamicSuffix, contains('【成员在线】'));
    expect(layered.full, contains('以下成员执行失败：Coder'));
  });
}
