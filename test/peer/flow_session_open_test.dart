import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
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

  test('A9-8: 卡片先到的频道标题干净，后续 session_title 能改名', () async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    final db = LocalDatabaseService();
    await db.database;
    const sessionId = 'flow_r9_a98_impl';
    const channelId = 'psess_$sessionId';
    const implicit = '[implicit]\n'
        'This message mentions pouch:// URI(s). Read it with pouch_read.\n'
        '[/implicit]';
    await db.deleteChannel(channelId);

    // 卡片问题里混着 [implicit] 提示块：不能直接拿整段当频道名。
    await ensureFlowSessionShell(
      channelId: channelId,
      agentId: 'agent-r9',
      title: '$implicit\n确认部署？',
      db: db,
    );
    var channel = await db.getChannelById(channelId);
    expect(channel, isNotNull);
    expect(channel!.name, '确认部署？');

    // 之后带 session_title 的 message.created 也走同一份建壳逻辑，但 A10-2
    // 之后已有的干净标题是正式名字，不能被主机消息 / 点击反复覆盖。
    final target =
        await PeerAgentClientService.instance.prepareLocalTargetForHubMessage(
      peerId: 'p1',
      remoteAgentId: 'agent-r9',
      sessionId: sessionId,
      rawChannelId: channelId,
      senderType: 'agent',
      fallbackSenderId: 'agent-r9',
      fallbackSenderName: '',
      sessionTitle: '主机给的节点标题',
    );
    expect(target.channelId, channelId);
    channel = await db.getChannelById(channelId);
    expect(channel!.name, '确认部署？', reason: '已起好的非占位标题不能被后续 session_title 覆盖');

    // 整段都是提示块时回落默认名，而不是把标记写进会话列表。
    const secondId = 'flow_r9_a98_impl2';
    const secondChannel = 'psess_$secondId';
    await db.deleteChannel(secondChannel);
    await ensureFlowSessionShell(
      channelId: secondChannel,
      agentId: 'agent-r9',
      title: implicit,
      db: db,
    );
    expect((await db.getChannelById(secondChannel))!.name, 'Session');
  });

  test('运行会话优先打开节点自己的 agent，没有节点会话才退回惜宝', () {
    final design = flowRunConversationTarget(const [
      FlowNode(
        key: 'design',
        id: 'design',
        kind: 'task',
        sessionId: 'flow_deadbe12_design',
        agentId: 'coder-agent',
      ),
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        sessionId: 'flow_deadbe12_impl',
        agentId: 'agent-7',
      ),
    ], sheSessionId: 'flow_deadbe12_she');
    expect(design?.sessionId, 'flow_deadbe12_design');
    expect(design?.agentId, 'coder-agent');

    final fallback = flowRunConversationTarget(const [
      FlowNode(key: 'ok', id: 'ok', kind: 'gate'),
    ], sheSessionId: 'flow_deadbe12_she');
    expect(fallback?.sessionId, 'flow_deadbe12_she');
    expect(fallback?.agentId, SheService.sheId);
    expect(flowRunConversationTarget(const []), isNull);
  });

  test('A10-2: 用户改名 / 主机标题不被 hub 消息或再次点击覆盖', () async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    final db = LocalDatabaseService();
    await db.database;
    const sessionId = 'flow_a102_impl';
    const channelId = 'psess_$sessionId';
    const implicit = '[implicit]\n'
        'This message mentions pouch:// URI(s). Read it with pouch_read.\n'
        '[/implicit]';
    await db.deleteChannel(channelId);

    final opened = <String>[];
    debugOpenFlowSessionChannel = (id, agent) async => opened.add(id);
    addTearDown(() => debugOpenFlowSessionChannel = null);

    // 频道刚由本函数创建：用清理过的干净标题。
    await ensureFlowSessionShell(
      channelId: channelId,
      agentId: 'agent-a10',
      title: '$implicit\n审查发布',
      db: db,
    );
    expect((await db.getChannelById(channelId))!.name, '审查发布');

    // 用户自己改名。
    await db.updateChannelName(channelId, '我改的名字');
    await PeerAgentClientService.instance.prepareLocalTargetForHubMessage(
      peerId: 'p1',
      remoteAgentId: 'agent-a10',
      sessionId: sessionId,
      rawChannelId: channelId,
      senderType: 'agent',
      fallbackSenderId: 'agent-a10',
      fallbackSenderName: '',
      sessionTitle: '主机给的真实流程名',
    );
    expect((await db.getChannelById(channelId))!.name, '我改的名字',
        reason: '用户改过的名字不能被每条 hub 消息覆盖');

    // 再从运行页点一次（泛化的 flow_sessionBanner 标题）。
    await openFlowSession(
      peerId: 'p1',
      sessionId: sessionId,
      remoteAgentId: 'agent-a10',
      title: '工作流 · 节点 impl',
      db: db,
    );
    expect(opened, [channelId]);
    expect((await db.getChannelById(channelId))!.name, '我改的名字');

    // 主机先给了真实流程名，随后的泛化标题同样不能覆盖。
    await db.updateChannelName(channelId, '发布流水线 v2');
    await openFlowSession(
      peerId: 'p1',
      sessionId: sessionId,
      remoteAgentId: 'agent-a10',
      title: '工作流 · 节点 impl',
      db: db,
    );
    expect((await db.getChannelById(channelId))!.name, '发布流水线 v2');

    // 当前名只是占位值时，仍允许主机下发的 session_title 纠正。
    const secondId = 'flow_a102_placeholder';
    const secondChannel = 'psess_$secondId';
    await db.deleteChannel(secondChannel);
    await ensureFlowSessionShell(
      channelId: secondChannel,
      agentId: 'agent-a10',
      title: implicit,
      db: db,
    );
    expect((await db.getChannelById(secondChannel))!.name, 'Session');
    await PeerAgentClientService.instance.prepareLocalTargetForHubMessage(
      peerId: 'p1',
      remoteAgentId: 'agent-a10',
      sessionId: secondId,
      rawChannelId: secondChannel,
      senderType: 'agent',
      fallbackSenderId: 'agent-a10',
      fallbackSenderName: '',
      sessionTitle: '主机给的真实流程名',
    );
    expect((await db.getChannelById(secondChannel))!.name, '主机给的真实流程名');
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
