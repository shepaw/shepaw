import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';

RemoteAgent _agent(
  String id,
  String name, {
  String? bio,
  List<String> capabilities = const [],
  bool local = false,
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
      metadata: {
        if (local) 'llm_provider': 'openai',
      },
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

  test('initial admin prompt instructs recon before clarification', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
    );

    expect(prompt, contains('先摸底，再澄清'));
    expect(prompt, contains('intent=recon'));
    expect(prompt, contains('group_finish'));
    expect(prompt, contains('pause'));
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

  test('plan missing nudge tells admin to publish plan before dispatch',
      () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
      isPlanMissingNudge: true,
    );

    expect(prompt, contains('group_plan_publish'));
    expect(prompt, contains('禁止'));
    expect(prompt, contains('group_dispatch'));
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

  test('admin prompt includes session management section', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
    );

    expect(prompt, contains('【群 Session 管理】'));
    expect(prompt, contains('group_session_create'));
    expect(prompt, contains('不强制一任务一 session'));
    expect(prompt, isNot(contains('session create **只有本群管理员')));
  });

  test('remote ACP admin prompt teaches hub.cli.execute, not shepaw store',
      () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: admin,
      isAdmin: true,
    );

    expect(prompt, contains('hub.cli.execute'));
    expect(prompt, contains('你没有 shepaw function tool'));
    expect(prompt, contains('session_id'));
    expect(prompt, isNot(contains('shepaw store write')));
    expect(prompt, isNot(contains('你有 shepaw CLI 工具')));
  });

  test('local LLM admin prompt still teaches shepaw store write', () async {
    final localAdmin = _agent('admin-local', 'LocalPM', local: true);
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [localAdmin, coder],
      currentAgent: localAdmin,
      isAdmin: true,
    );

    expect(prompt, contains('shepaw store write'));
    expect(prompt, isNot(contains('你没有 shepaw function tool')));
    expect(prompt, isNot(contains('hub.cli.execute')));
  });

  test('remote ACP member prompt uses hub store write', () async {
    final prompt = await builder.buildGroupSystemPrompt(
      groupName: '项目群',
      groupDescription: '',
      allAgents: [admin, coder],
      currentAgent: coder,
      isAdmin: false,
    );

    expect(prompt, contains('hub.cli.execute'));
    expect(prompt, contains('namespace=store'));
    expect(prompt, isNot(contains('shepaw store write')));
  });
}
