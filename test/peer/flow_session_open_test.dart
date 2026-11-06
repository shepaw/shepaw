import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  test('P4: node session channel id is the psess_ shell', () {
    expect(
        flowSessionChannelId('flow_deadbe12_impl'), 'psess_flow_deadbe12_impl');
    expect(flowSessionChannelId('  flow_deadbe12_impl  '),
        'psess_flow_deadbe12_impl');
  });

  test('P4: agent id falls back to the Hub-side id when no local row exists',
      () async {
    expect(
      await resolveFlowAgentLocalId(
        peerId: 'p1',
        remoteAgentId: 'agent-7',
      ),
      'agent-7',
    );
    expect(
      await resolveFlowAgentLocalId(peerId: 'p1', remoteAgentId: ''),
      '',
    );
  });

  test('A2-7: 空 agentId 不建只有 user 的空频道 / 不塞空成员', () async {
    await StorageTestHarness.init();
    final db = LocalDatabaseService();
    await db.database;
    const channelId = 'psess_flow_a27empty_impl';
    await db.deleteChannel(channelId);

    await ensureFlowSessionShell(
      channelId: channelId,
      agentId: '',
      title: 'impl',
      db: db,
    );
    expect(await db.getChannelById(channelId), isNull,
        reason: '没有 agent 可当成员时不该建壳');

    // 有 agentId 时仍按原逻辑建壳。
    await ensureFlowSessionShell(
      channelId: channelId,
      agentId: 'agent-7',
      title: 'impl',
      db: db,
    );
    expect(await db.getChannelById(channelId), isNotNull);
    expect(
      await db.getChannelMemberIds(channelId),
      containsAll(<String>['user', 'agent-7']),
    );
  });

  test('A2-9: 运行会话用 SheService.sheId，而不是第四份字面量', () async {
    ({String channelId, String? agentId})? opened;
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened = (channelId: channelId, agentId: agentId);
    };
    addTearDown(() => debugOpenFlowSessionChannel = null);

    await openFlowRunSession(
      peerId: 'p1',
      runSheSessionId: 'flow_deadbe12_she',
    );
    expect(opened?.channelId, 'psess_flow_deadbe12_she');
    // 没有本机行时 remoteAgentId 原样成为本地 agent id；这里必须是共享的
    // SheService.sheId，换回独立字面量一旦两边漂移就会立刻失败。
    expect(opened?.agentId, SheService.sheId);
  });
}
