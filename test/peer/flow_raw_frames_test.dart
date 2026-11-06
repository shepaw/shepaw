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

    // 回合缓存也随最终消息清掉：同一 turnId 再来 chunk 需要重新解析。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('下一轮'),
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

  test('A2-6: message.created 收尾后占位集合也清掉，后续 chunk 能重建占位', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      seqStore: MemoryHubSeqStore(),
    );
    client.start();
    addTearDown(client.dispose);
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(_turnId));
    await db.deleteMessage('msg-final-a26');

    // 先有流式占位。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: _flowChunk('半截')));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(_turnId)) != null,
    );

    // 回合结束：主机 append 最终消息，清理循环应同时移除 _flowPlaceholders。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowFinalMessage('msg-final-a26'),
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(_turnId)) == null,
    );

    // 同一个 turnId 再来 chunk：占位集合若没清，这里会建不出占位。
    incoming.add(PeerControlEvent(peerId: 'peer-1', data: _flowChunk('再来')));
    await _until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(_turnId));
      return (row?['content'] as String? ?? '').contains('再来');
    });
    expect(await db.getMessageById(liveTurnPlaceholderId(_turnId)), isNotNull,
        reason: '占位集合未清会导致后续 chunk 建不出占位');
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

  test('A3-1: 不带 agent_id 的 metadata 不缓存空目标，chunk 仍能正确归属', () async {
    const sessionId = 'flow_a31_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a31-impl-a1';
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

    // 主机原生 metadata 帧没有 agent_id：不能拿空 sender 去解析并缓存。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_metadata',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'run_id': 'a31run',
        'node': 'impl',
        'metadata': {'kind': 'thinking'},
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(client.debugFlowControlTargetResolves, 0,
        reason: '没有 agent_id 的 metadata 不该去解析落点（会缓存空目标）');

    // 稍后带 agent_id 的 chunk 仍要解析出正确的 sender 并建好频道壳。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'agent_id': 'agent-7',
        'run_id': 'a31run',
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
    expect(row!['sender_id'], 'agent-7',
        reason: 'metadata 不能把空 sender 缓存给 chunk 复用');
    expect(await db.getChannelById(row['channel_id'] as String), isNotNull,
        reason: 'chunk 解析时应把频道壳建好');
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
}
