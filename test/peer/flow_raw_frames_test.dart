import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/peer/hub_event_apply.dart' show liveTurnPlaceholderId;
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

const _sessionId = 'flow_deadbe12_impl';
const _channelId = 'psess_$_sessionId';
const _turnId = 'flow-deadbe12-impl-a1';

Map<String, dynamic> _flowChunk(String content) => {
      'type': 'agent_chunk',
      'request_id': _turnId,
      'turn_id': _turnId,
      'generation': 1,
      'channel_id': _channelId,
      'session_id': _sessionId,
      'session_key': _sessionId,
      'agent_id': 'agent-7',
      'run_id': 'deadbe12-1234',
      'node': 'impl',
      'content': content,
    };

Map<String, dynamic> _sessionState(String status) => {
      'type': 'session.state',
      // 主机对节点会话的帧会带 `flow: true`，revision 按 key 独立计数。
      'flow': true,
      'session_key': _sessionId,
      'channel_id': _channelId,
      'status': status,
      'turn_id': _turnId,
      'revision': status == 'running' ? 1 : 2,
      'peer_id': 'peer-1',
      'ask_enabled': true,
      'generation': 1,
      'hub_id': 'hub-flow',
    };

/// A4-8：主机真实发出的 flow metadata 帧（H4-11 起带 `agent_id`）。
/// 字段组合和 node_runtime 转发出来的一致：request_id / turn_id /
/// channel_id / session_id / agent_id / run_id / node / metadata。
Map<String, dynamic> _flowMetadata() => {
      'type': 'agent_metadata',
      'request_id': _turnId,
      'turn_id': _turnId,
      'channel_id': _channelId,
      'session_id': _sessionId,
      'agent_id': 'agent-7',
      'run_id': 'deadbe12-1234',
      'node': 'impl',
      'metadata': {'kind': 'thinking'},
    };

Map<String, dynamic> _flowFinalMessage(String id) => {
      'type': 'hub_event',
      'event': {
        'seq': 1,
        'kind': 'message.created',
        'channel_id': _channelId,
        'agent_id': 'agent-7',
        'data': {
          'id': id,
          'channel_id': _channelId,
          'session_id': _sessionId,
          'agent_id': 'agent-7',
          'content': '最终回复',
          'type': 'text',
          'from': {'id': 'agent-7', 'type': 'agent', 'name': 'Impl'},
        },
      },
    };

Future<void> _until(FutureOr<bool> Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待超时');
}

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    setupServiceLocator();
    await LocalDatabaseService().database;
  });

  test('P4: session.state is a control frame (otherwise it never arrives)', () {
    expect(PeerConnection.isControlFrameType('session.state'), isTrue);
    expect(PeerConnection.isControlFrameType('agent_chunk'), isTrue);
    expect(PeerConnection.isControlFrameType('agent_metadata'), isTrue);
  });

  test('P4: raw session.state (status alias) feeds SessionRuntimeMirror',
      () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(events: incoming.stream);
    client.start();
    addTearDown(client.dispose);
    final mirror = getIt<SessionRuntimeMirror>();
    mirror.reconcileTo(const [], hubId: 'hub-flow');

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _sessionState('running'),
    ));
    await _until(
      () async => mirror.stateFor(_sessionId).turnId == _turnId,
    );
    expect(mirror.stateFor(_sessionId).isRunning, isTrue);
    expect(mirror.stateFor(_sessionId).peerId, 'peer-1');

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _sessionState('idle'),
    ));
    await _until(() async => !mirror.stateFor(_sessionId).isRunning);
    await incoming.close();
  });

  test('P4: agent_chunk is routed by channel_id and shows live text', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(_turnId));
    client.debugFlowControlTargetResolves = 0;

    // 普通 DM 的 chunk 不带 flow 标记：不该被这条路径接走。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': 'dm-1',
        'channel_id': 'dm_other',
        'content': '不该出现',
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await db.getMessageById(liveTurnPlaceholderId('dm-1')), isNull);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('正在写'),
    ));
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('实现'),
    ));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(_turnId));
      return (row?['content'] as String? ?? '').contains('正在写实现');
    });
    expect(await db.getChannelById(_channelId), isNotNull);
    // A8：同一回合的两片 chunk 复用落点解析（查库 / 建壳只做一次）。
    expect(client.debugFlowControlTargetResolves, 1,
        reason: '同一 peer + turn 的后续 chunk 不该再解析一次落点');

    // idle 只 flush、不立刻删占位：主机可能随后才 append 最终消息（A3-4）。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _sessionState('idle'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final kept = await db.getMessageById(liveTurnPlaceholderId(_turnId));
    expect(kept, isNotNull, reason: 'idle 后占位要留到最终 message.created');
    expect(kept?['content'] as String? ?? '', contains('正在写实现'),
        reason: 'idle 不能把已经流出来的正文丢掉');

    // 最终消息到达后占位才被收掉。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowFinalMessage('msg-final-p4'),
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(_turnId)) == null,
    );
    expect(await db.getMessageById('msg-final-p4'), isNotNull);

    // A4-4：收尾后同一 turnId 的迟到 chunk 被丢弃，不再解析 / 重建占位。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('迟到'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(client.debugFlowControlTargetResolves, 1,
        reason: '已收尾回合的迟到 chunk 不该再解析落点');
    expect(await db.getMessageById(liveTurnPlaceholderId(_turnId)), isNull);

    // 新回合（新 turnId）照常解析：落点缓存确实随收尾清掉了。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('下一轮')
        ..['turn_id'] = 'flow-deadbe12-impl-b1'
        ..['request_id'] = 'flow-deadbe12-impl-b1',
    ));
    await _until(() async => client.debugFlowControlTargetResolves == 2);
    expect(client.debugFlowControlTargetResolves, 2, reason: '最终消息应清掉该回合的落点缓存');
    await incoming.close();
  });

  test('A2-5: 同回合的 agent_metadata 与 chunk 只解析一次落点', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(_turnId));
    client.debugFlowControlTargetResolves = 0;

    // metadata 先到：它要负责建好本地壳，并把落点解析缓存下来。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: _flowMetadata()));
    await _until(() async => client.debugFlowControlTargetResolves == 1);

    incoming.add(PeerControlEvent(peerId: 'peer-1', data: _flowChunk('合并')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(_turnId));
      return (row?['content'] as String? ?? '').contains('合并');
    });
    expect(client.debugFlowControlTargetResolves, 1,
        reason: 'chunk 应复用 metadata 解析好的 peer + turn 缓存');
    await incoming.close();
  });

  test('A4-4: 收尾后的迟到 chunk 不重建占位，也不留流式残留', () async {
    const turnId = 'flow-a44-late-a1';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
      flowIdleFinalizeDelay: const Duration(milliseconds: 60),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage('msg-final-a44');

    Map<String, dynamic> chunk(String content) => {
          'type': 'agent_chunk',
          'request_id': turnId,
          'turn_id': turnId,
          'channel_id': _channelId,
          'session_id': _sessionId,
          'agent_id': 'agent-7',
          'run_id': 'a44run',
          'node': 'impl',
          'content': content,
        };
    Map<String, dynamic> idle() => {
          'type': 'session.state',
          'flow': true,
          'session_key': _sessionId,
          'channel_id': _channelId,
          'status': 'idle',
          'turn_id': turnId,
          'revision': 2,
          'peer_id': 'peer-1',
          'hub_id': 'hub-flow',
        };

    // 先有流式占位，再让最终消息把它收掉。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('半截')));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(turnId)) != null,
    );
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowFinalMessage('msg-final-a44'),
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(turnId)) == null,
    );

    // 最终消息之后迟到的一片 chunk：不能当成新回合重建 streaming 占位。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('迟到')));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNull,
        reason: '已收尾回合的迟到 chunk 不该重建占位');

    // idle 超时收尾的路径同理：保留的正文不被迟到 chunk 改回 streaming。
    const idleTurn = 'flow-a44-idle-a1';
    await db.deleteMessage(liveTurnPlaceholderId(idleTurn));
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': idleTurn,
        'turn_id': idleTurn,
        'channel_id': _channelId,
        'session_id': _sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a44run',
        'node': 'impl',
        'content': '超时前的正文',
      },
    ));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(idleTurn));
      return (row?['content'] as String? ?? '').contains('超时前的正文');
    });
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: idle()..['turn_id'] = idleTurn,
    ));
    // 等 idle 超时把占位收成终态。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final finalized = await db.getMessageById(liveTurnPlaceholderId(idleTurn));
    expect(finalized, isNotNull);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': idleTurn,
        'turn_id': idleTurn,
        'channel_id': _channelId,
        'session_id': _sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a44run',
        'node': 'impl',
        'content': '迟到',
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final after = await db.getMessageById(liveTurnPlaceholderId(idleTurn));
    expect(after?['content'] as String? ?? '', '超时前的正文',
        reason: '迟到 chunk 不能改已收尾的占位');
    final meta = after?['metadata'];
    expect(meta is String ? jsonDecode(meta) : meta,
        isNot(containsPair('status', 'streaming')));
    await incoming.close();
  });

  test('P4: agent_metadata without a local _pending still builds the shell',
      () async {
    const otherSession = 'flow_deadbe12_meta';
    const otherChannel = 'psess_$otherSession';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(events: incoming.stream);
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteChannel(otherChannel);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_metadata',
        'turn_id': 'flow-deadbe12-meta-a1',
        'channel_id': otherChannel,
        'session_id': otherSession,
        'agent_id': 'agent-7',
        'run_id': 'deadbe12-1234',
        'node': 'meta',
        'metadata': {'kind': 'thinking'},
      },
    ));
    await _until(() async => await db.getChannelById(otherChannel) != null);
    expect(await db.getChannelById(otherChannel), isNotNull);
    await incoming.close();
  });

  test('A4-8: 真实 metadata 帧（带 agent_id）预热落点缓存并建壳', () async {
    const sessionId = 'flow_a48_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a48-impl-a1';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteChannel(channelId);
    client.debugFlowControlTargetResolves = 0;

    // 主机发出来的帧形状：带 agent_id，因此 metadata 就该负责建壳并缓存。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_metadata',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a48run',
        'node': 'impl',
        'metadata': {'kind': 'thinking'},
      },
    ));
    await _until(() async => client.debugFlowControlTargetResolves == 1);
    expect(await db.getChannelById(channelId), isNotNull,
        reason: '真实 metadata 帧应把频道壳建好');

    // 同回合 chunk 复用 metadata 解析出的落点（sender 不能是空）。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a48run',
        'node': 'impl',
        'content': '正文',
      },
    ));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('正文');
    });
    expect(client.debugFlowControlTargetResolves, 1);
    final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(row, isNotNull);
    expect(row!['sender_id'], 'agent-7');
    await incoming.close();
  });

  test('A3-2: 解析期间回合被清掉后，晚到的 chunk 不再重建占位', () async {
    const sessionId = 'flow_a32_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a32-impl-a1';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    client.debugFlowControlTargetResolves = 0;

    final gate = Completer<void>();
    client.debugBeforeFlowChunkResolve = () => gate.future;
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a32run',
        'node': 'impl',
        'content': '半截',
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(client.debugFlowControlTargetResolves, 0, reason: '已被闸门卡住');

    // 解析还没回来，回合先结束了（这里用 turn.finished；idle 在 A3-4 里
    // 改成保留占位，不再立即清回合）。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.finished',
          'channel_id': channelId,
          'agent_id': 'agent-7',
          'data': {'turn_id': turnId},
        },
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNull,
        reason: '回合已清掉，await 回来的 chunk 不能再把占位重建出来');
    expect(client.debugFlowControlTargetResolves, 1,
        reason: '解析本身应该已经完成（只是结果被丢弃）');
    await incoming.close();
  });

  test('A3-4: idle 保留占位，最终消息到达后才删；没有最终消息则超时收尾不丢正文', () async {
    const sessionId = 'flow_a34_impl';
    const channelId = 'psess_$sessionId';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
      flowIdleFinalizeDelay: const Duration(milliseconds: 80),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();

    Map<String, dynamic> chunk(String turnId, String content) => {
          'type': 'agent_chunk',
          'request_id': turnId,
          'turn_id': turnId,
          'channel_id': channelId,
          'session_id': sessionId,
          'agent_id': 'agent-7',
          'run_id': 'a34run',
          'node': 'impl',
          'content': content,
        };
    Map<String, dynamic> idle(String turnId) => {
          'type': 'session.state',
          'session_key': sessionId,
          'channel_id': channelId,
          'status': 'idle',
          'turn_id': turnId,
          'revision': 2,
          'peer_id': 'peer-1',
          'ask_enabled': true,
          'hub_id': 'hub-flow',
        };
    Map<String, dynamic> finalMessage(String id) => {
          'type': 'hub_event',
          'event': {
            'seq': 1,
            'kind': 'message.created',
            'channel_id': channelId,
            'agent_id': 'agent-7',
            'data': {
              'id': id,
              'channel_id': channelId,
              'session_id': sessionId,
              'agent_id': 'agent-7',
              'content': '最终回复',
              'type': 'text',
              'from': {'id': 'agent-7', 'type': 'agent', 'name': 'Impl'},
            },
          },
        };

    // 1) 有最终消息：idle 后占位还在，最终消息到了才删。
    const turnKeep = 'flow-a34-keep-a1';
    await db.deleteMessage(liveTurnPlaceholderId(turnKeep));
    await db.deleteMessage('msg-a34-final');
    incoming
        .add(PeerControlEvent(peerId: 'peer-1', data: chunk(turnKeep, '流式正文')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnKeep));
      return (row?['content'] as String? ?? '').contains('流式正文');
    });
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: idle(turnKeep)));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final kept = await db.getMessageById(liveTurnPlaceholderId(turnKeep));
    expect(kept, isNotNull, reason: 'idle 不能立刻删占位');
    expect(kept?['content'] as String? ?? '', contains('流式正文'));
    incoming.add(PeerControlEvent(
        peerId: 'peer-1', data: finalMessage('msg-a34-final')));
    await _until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnKeep)) == null);
    expect(await db.getMessageById('msg-a34-final'), isNotNull);

    // 2) 没有最终消息（失败 / 取消）：超时后占位保留、正文不丢、停掉流式标记。
    const turnLost = 'flow-a34-lost-a1';
    await db.deleteMessage(liveTurnPlaceholderId(turnLost));
    incoming.add(
        PeerControlEvent(peerId: 'peer-1', data: chunk(turnLost, '失败前的输出')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnLost));
      return (row?['content'] as String? ?? '').contains('失败前的输出');
    });
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: idle(turnLost)));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnLost));
      if (row == null) return false;
      final meta = row['metadata'];
      return meta is String ? !meta.contains('streaming') : true;
    });
    final lost = await db.getMessageById(liveTurnPlaceholderId(turnLost));
    expect(lost, isNotNull, reason: '没有最终消息时不能删掉已流出的正文');
    expect(lost?['content'] as String? ?? '', contains('失败前的输出'));
    final lostMeta = lost?['metadata'];
    expect(lostMeta is String ? jsonDecode(lostMeta) : lostMeta,
        isNot(containsPair('status', 'streaming')));
    await incoming.close();
  });

  test('A5-1: 重启后重放最终消息，仍能删掉 idle 收尾留下的占位', () async {
    const sessionId = 'flow_a51_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a51-impl-a1';
    const finalId = 'msg-a51-final';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final first = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
      flowIdleFinalizeDelay: const Duration(milliseconds: 60),
    );
    first.start();
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(finalId);

    Map<String, dynamic> chunk(String content) => {
          'type': 'agent_chunk',
          'request_id': turnId,
          'turn_id': turnId,
          'channel_id': channelId,
          'session_id': sessionId,
          'agent_id': 'agent-7',
          'run_id': 'a51run',
          'node': 'impl',
          'content': content,
        };

    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('收尾前的正文')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('收尾前的正文');
    });
    // idle 后没有最终消息：超时把占位收成终态，但行保留。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'session.state',
        'flow': true,
        'session_key': sessionId,
        'channel_id': channelId,
        'status': 'idle',
        'turn_id': turnId,
        'revision': 2,
        'peer_id': 'peer-1',
        'hub_id': 'hub-flow',
      },
    ));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      if (row == null) return false;
      final meta = row['metadata'];
      return meta is! String || !meta.contains('streaming');
    });
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNotNull,
        reason: '收尾后占位要保留，等最终消息到了再删');

    // 模拟 App 重启：内存里的回合索引全没了，换一个 client 实例。
    await first.dispose();
    final second = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    second.start();
    addTearDown(second.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': 'agent-7',
          'data': {
            'id': finalId,
            'channel_id': channelId,
            'session_id': sessionId,
            'agent_id': 'agent-7',
            'content': '最终回复',
            'type': 'text',
            'from': {'id': 'agent-7', 'type': 'agent', 'name': 'Impl'},
          },
        },
      },
    ));

    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(turnId)) == null,
    );
    expect(await db.getMessageById(finalId), isNotNull);
    expect(await db.listLiveTurnPlaceholderIds(channelId), isEmpty,
        reason: '重启后重放最终消息也必须把确定性 id 的占位删干净');
    await incoming.close();
  });

  test('A5-2: 首帧缺 agent_id 时兜底落点不写缓存，下一帧重新解析', () async {
    const sessionId = 'flow_a52_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a52-impl-a1';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteChannel(channelId);
    client.debugFlowControlTargetResolves = 0;

    Map<String, dynamic> chunk(String content) => {
          'type': 'agent_chunk',
          'request_id': turnId,
          'turn_id': turnId,
          'channel_id': channelId,
          'session_id': sessionId,
          'agent_id': 'agent-7',
          'run_id': 'a52run',
          'node': 'impl',
          'content': content,
        };

    // 第一帧没有 agent_id：只能解析出「裸 channel + 空 sender」的兜底结果。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: chunk('前半')..remove('agent_id'),
    ));
    await _until(() async => client.debugFlowControlTargetResolves == 1);
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNull,
        reason: '兜底落点缺 sender，不能先建一个补不回 sender 的占位');

    // 第二帧带 agent_id：必须重新解析，而不是复用上一帧的兜底缓存。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('后半')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('前半后半');
    });
    expect(client.debugFlowControlTargetResolves, 2, reason: '不完整的落点不能缓存');
    expect(await db.getChannelById(channelId), isNotNull,
        reason: '带 agent_id 的帧要负责把本地壳建好');
    final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(row!['sender_id'], 'agent-7');
    await incoming.close();
  });

  test('A5-3: idle 后的迟到 chunk 会重新起收尾计时，最终仍会停', () async {
    const sessionId = 'flow_a53_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a53-impl-a1';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
      flowIdleFinalizeDelay: const Duration(milliseconds: 80),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));

    Map<String, dynamic> chunk(String content) => {
          'type': 'agent_chunk',
          'request_id': turnId,
          'turn_id': turnId,
          'channel_id': channelId,
          'session_id': sessionId,
          'agent_id': 'agent-7',
          'run_id': 'a53run',
          'node': 'impl',
          'content': content,
        };

    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('前半')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('前半');
    });

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'session.state',
        'flow': true,
        'session_key': sessionId,
        'channel_id': channelId,
        'status': 'idle',
        'turn_id': turnId,
        'revision': 2,
        'peer_id': 'peer-1',
        'hub_id': 'hub-flow',
      },
    ));
    // 等 idle 处理完（计时器已起），再补一片迟到 chunk。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: chunk('迟到')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('前半迟到');
    });

    // 之后不再有帧：重新起的计时器必须把占位收成终态（停掉 streaming）。
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      final meta = row?['metadata'];
      return meta is! String || !meta.contains('streaming');
    });
    final settled = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(settled?['content'] as String? ?? '', contains('前半迟到'));
    await incoming.close();
  });

  test('A5-4: 清理占位时不关仍在等待作答的交互卡', () async {
    const sessionId = 'flow_a54_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a54-impl-a1';
    const interactionId = 'ix-a54-pending';
    const agentMsgId = 'msg-a54-progress';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(HubEventClient.hubCardMessageId(interactionId));
    await db.deleteMessage(agentMsgId);

    Map<String, dynamic> flowEvent(
            int seq, String kind, Map<String, dynamic> data) =>
        {
          'type': 'hub_event',
          'event': {
            'seq': seq,
            'kind': kind,
            'channel_id': channelId,
            'agent_id': 'agent-7',
            'data': data,
          },
        };

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a54run',
        'node': 'impl',
        'content': '正在做',
      },
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(turnId)) != null,
    );

    // 回合问了一个还没答的问题。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: flowEvent(1, 'interaction.pending', {
        'interaction_id': interactionId,
        'turn_id': turnId,
        'agent_id': 'agent-7',
        'interaction_type': 'action_confirmation',
        'data': {
          'interaction_id': interactionId,
          'confirmation_id': interactionId,
          'prompt': '允许吗？',
        },
      }),
    ));
    final cardId = HubEventClient.hubCardMessageId(interactionId);
    await _until(() async => await db.getMessageById(cardId) != null);

    // 同频道来一条 agent 普通消息：清理占位，但不能把还在等的卡标成结束。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: flowEvent(2, 'message.created', {
        'id': agentMsgId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'content': '进度汇报',
        'type': 'text',
        'from': {'id': 'agent-7', 'type': 'agent', 'name': 'Impl'},
      }),
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(turnId)) == null,
    );
    final card = await db.getMessageById(cardId);
    final metadata =
        jsonDecode(card!['metadata'] as String) as Map<String, dynamic>;
    final payload = metadata['action_confirmation'] as Map;
    expect(payload['closed'], isNull, reason: '卡片还在等回答，不能提前关掉');

    // 真正的回合终态才收卡。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: flowEvent(3, 'turn.finished', {'turn_id': turnId}),
    ));
    await _until(() async {
      final row = await db.getMessageById(cardId);
      final meta =
          jsonDecode(row!['metadata'] as String) as Map<String, dynamic>;
      return (meta['action_confirmation'] as Map)['closed'] != null;
    });
    final closed = jsonDecode(
      (await db.getMessageById(cardId))!['metadata'] as String,
    ) as Map<String, dynamic>;
    expect((closed['action_confirmation'] as Map)['closed'], 'turn_ended');
    await incoming.close();
  });
}
