import 'dart:async';

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
    final client = HubEventClient(events: incoming.stream);
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

    // idle 快照收掉占位；终态正文由主机 append 的 message.created 落库。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _sessionState('idle'),
    ));
    await _until(
      () async =>
          await db.getMessageById(liveTurnPlaceholderId(_turnId)) == null,
    );
    // 回合缓存也随 idle 清掉：同一 turnId 再来 chunk 需要重新解析。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: _flowChunk('下一轮'),
    ));
    await _until(() async => client.debugFlowControlTargetResolves == 2);
    expect(client.debugFlowControlTargetResolves, 2,
        reason: 'idle 应清掉该回合的落点缓存');
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
}
