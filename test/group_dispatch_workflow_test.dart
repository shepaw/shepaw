import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
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
}
