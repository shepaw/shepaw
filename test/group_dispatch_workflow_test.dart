import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_orchestration_service.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/services/local_database_service.dart';

void main() {
  final parser = GroupDispatchParser(LocalDatabaseService());

  final agents = [
    RemoteAgent(
      id: 'a1',
      name: 'Coder',
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    ),
    RemoteAgent(
      id: 'a2',
      name: 'Reviewer',
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    ),
  ];

  test('buildFlowPlanFromDispatch groups concurrent steps in one stage', () {
    final dispatch = parser.parseStructuredDispatch(
      '''分派任务：
```json
{"dispatch":{"mode":"concurrent","steps":[{"step":1,"agents":["Coder","Reviewer"],"task":"实现功能"}]},"continue":false,"done":false}
```''',
      agents,
    );

    final plan = parser.buildFlowPlanFromDispatch(
      steps: dispatch.steps,
      mode: dispatch.steps.first.mode,
      agents: agents,
      summary: '用户请求',
      title: '测试群',
    );

    expect(plan.stages.length, 1);
    expect(plan.stages.first.steps.length, 2);
    expect(plan.stages.first.steps[0].agent, 'Coder');
    expect(plan.stages.first.steps[1].agent, 'Reviewer');
  });

  test('parseStructuredDispatch matches agent names case-insensitively', () {
    final mixedCaseAgents = [
      RemoteAgent(
        id: 'a1',
        name: 'Shepaw',
        avatar: '🤖',
        token: '',
        endpoint: '',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        createdAt: 0,
        updatedAt: 0,
      ),
    ];

    final dispatch = parser.parseStructuredDispatch(
      '''```json
{"dispatch":{"mode":"concurrent","steps":[{"step":1,"agents":["shepaw"],"task":"修复键盘遮挡"}]},"continue":false,"done":false}
```''',
      mixedCaseAgents,
    );

    expect(dispatch.steps.length, 1);
    expect(dispatch.steps.first.agentIds, ['a1']);
  });

  test('buildFlowPlanFromDispatch splits sequential steps into stages', () {
    final dispatch = parser.parseStructuredDispatch(
      '''```json
{"dispatch":{"mode":"sequential","steps":[{"step":1,"agents":["Coder"],"task":"写代码"},{"step":2,"agents":["Reviewer"],"task":"审查"}]},"continue":false,"done":false}
```''',
      agents,
    );

    final plan = parser.buildFlowPlanFromDispatch(
      steps: dispatch.steps,
      mode: dispatch.steps.first.mode,
      agents: agents,
      summary: '用户请求',
    );

    expect(plan.stages.length, 2);
    expect(plan.stages[0].steps.single.agent, 'Coder');
    expect(plan.stages[1].steps.single.agent, 'Reviewer');
  });

  test('taskContentForAgent uses DispatchStep.task instead of user fallback', () {
    final steps = [
      const DispatchStep(
        step: 1,
        agentIds: ['a1'],
        task: '实现登录',
        mode: 'concurrent',
      ),
      const DispatchStep(
        step: 2,
        agentIds: ['a2'],
        task: '写测试',
        mode: 'concurrent',
      ),
    ];
    expect(
      GroupDispatchParser.taskContentForAgent(
        agentId: 'a1',
        steps: steps,
        fallback: '用户原文',
      ),
      '实现登录',
    );
    expect(
      GroupDispatchParser.taskContentForAgent(
        agentId: 'a2',
        steps: steps,
        fallback: '用户原文',
      ),
      '写测试',
    );
    expect(
      GroupDispatchParser.taskContentForAgent(
        agentId: 'missing',
        steps: steps,
        fallback: '用户原文',
      ),
      '用户原文',
    );
  });

  test('buildMemberTurnContent injects global requirement plus local task', () {
    final content = GroupDispatchParser.buildMemberTurnContent(
      memberBrief: '实现登录',
      globalRequirement: '用户完整需求原文',
      memoryNote: '\n[群记忆] 摘要',
    );
    expect(content, contains('【全局需求】'));
    expect(content, contains('用户完整需求原文'));
    expect(content, contains('【你的任务】'));
    expect(content, contains('实现登录'));
    expect(content, contains('群记忆'));
  });

  test('buildMemberTurnContent avoids duplicating when brief is the fallback', () {
    final content = GroupDispatchParser.buildMemberTurnContent(
      memberBrief: '用户完整需求原文',
      globalRequirement: '用户完整需求原文',
      memoryNote: '\n[群记忆] 摘要',
    );
    expect(content, isNot(contains('【你的任务】')));
    expect('用户完整需求原文'.allMatches(content).length, 1);
    expect(content, contains('群记忆'));
  });

  test('extractStoreUris pulls unique store URIs and trims punctuation', () {
    const reply = '完成，产物见 [a](store://workspaces/dev/group_1/shared/a.md)。'
        '以及 store://workspaces/dev/group_1/shared/b.md, '
        '重复的 store://workspaces/dev/group_1/shared/a.md';
    final uris = GroupOrchestrationService.extractStoreUris(reply);
    expect(uris, [
      'store://workspaces/dev/group_1/shared/a.md',
      'store://workspaces/dev/group_1/shared/b.md',
    ]);
    expect(GroupOrchestrationService.extractStoreUris('没有产物'), isEmpty);
  });

  test('buildMemberArtifactsBlock lists member artifacts', () {
    final results = <String, GroupTurnResult>{
      'a1': const GroupTurnResult(
        content: '产物：store://workspaces/dev/group_1/shared/c.md',
      ),
      'a2': const GroupTurnResult(content: '纯文本回复'),
    };
    final block = GroupOrchestrationService.buildMemberArtifactsBlock(
      results,
      agents,
    );
    expect(block, contains('【成员产物】'));
    expect(block, contains('Coder'));
    expect(block, contains('store://workspaces/dev/group_1/shared/c.md'));
    expect(block, isNot(contains('Reviewer')));

    expect(
      GroupOrchestrationService.buildMemberArtifactsBlock(
        const {'a1': GroupTurnResult(content: '无产物')},
        agents,
      ),
      isEmpty,
    );
  });

  test('parseStructuredDispatch recognizes pause', () {
    final dispatch = parser.parseStructuredDispatch(
      '''```json
{"pause": true}
```''',
      agents,
    );
    expect(dispatch.isPause, isTrue);
    expect(dispatch.isDone, isTrue);
    expect(dispatch.steps, isEmpty);
  });
}
