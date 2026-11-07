import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/hub_event_apply.dart'
    show liveTurnPlaceholderId, liveTurnPlaceholderPrefix;
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 第九轮评审：占位生命周期 / 重登保护 / 重试激活 / attached 兜底 / 热路径。
///
/// 每条用例都钉在一个真实故障场景上，用唯一的频道 / turn id 隔离，避免和
/// 别的用例共用同一份 ffi SQLite 时互相污染。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    setupServiceLocator();
    await LocalDatabaseService().database;
  });

  Future<void> until(FutureOr<bool> Function() ready) async {
    for (var i = 0; i < 150; i++) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  Map<String, dynamic> chunk(
    String turnId,
    String channelId,
    String sessionId,
    String content, {
    Object? generation,
  }) =>
      {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        if (generation != null) 'generation': generation,
        'channel_id': channelId,
        'session_id': sessionId,
        'session_key': sessionId,
        'agent_id': 'agent-r9',
        'run_id': 'r9run',
        'node': 'impl',
        'content': content,
      };

  Map<String, dynamic> state(
    String status,
    String turnId,
    String channelId,
    String sessionId, {
    int revision = 2,
    Object? epoch,
  }) =>
      {
        'type': 'session.state',
        'flow': true,
        'session_key': sessionId,
        'channel_id': channelId,
        'status': status,
        'turn_id': turnId,
        'revision': revision,
        'peer_id': 'peer-r9',
        'hub_id': 'hub-r9',
        if (epoch != null) 'epoch': epoch,
      };

  Map<String, dynamic> created(
    int seq,
    String channelId,
    String sessionId,
    String id, {
    Map<String, dynamic>? metadata,
  }) =>
      {
        'type': 'hub_event',
        'event': {
          'seq': seq,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': 'agent-r9',
          'data': {
            'id': id,
            'channel_id': channelId,
            'session_id': sessionId,
            'agent_id': 'agent-r9',
            'content': id,
            'type': 'text',
            if (metadata != null) 'metadata': metadata,
            'from': {'id': 'agent-r9', 'type': 'agent', 'name': 'R9'},
          },
        },
      };

  HubEventClient clientFor(
    Stream<PeerControlEvent> events, {
    Duration idle = const Duration(milliseconds: 60),
    Duration fallback = const Duration(seconds: 5),
    String fingerprint = 'fp-r9',
  }) =>
      HubEventClient(
        events: events,
        send: (_, __) async => true,
        seqStore: MemoryHubSeqStore(),
        fingerprintOf: (_) async => fingerprint,
        watchingTurn: (_) => false,
        flowIdleFinalizeDelay: idle,
        flowFallbackFinalizeDelay: fallback,
      );

  Future<bool> isFinalized(String turnId) async {
    final row = await getIt<LocalDatabaseService>()
        .getMessageById(liveTurnPlaceholderId(turnId));
    final raw = row?['metadata'];
    if (raw is! String) return false;
    try {
      return jsonDecode(raw) is Map &&
          (jsonDecode(raw) as Map)['finalized'] == true;
    } catch (_) {
      return false;
    }
  }

  test('A9-2: 另一个回合的最终回复不删掉已 retain 的半段回答', () async {
    const sessionId = 'flow_r9_a92_impl';
    const channelId = 'psess_$sessionId';
    const retainedTurn = 'flow-r9-a92-old';
    const newTurn = 'flow-r9-a92-new';
    const finalId = 'msg-r9-a92-final';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(retainedTurn));
    await db.deleteMessage(liveTurnPlaceholderId(newTurn));
    await db.deleteMessage(finalId);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client =
        clientFor(incoming.stream, idle: const Duration(milliseconds: 40));
    client.start();
    addTearDown(client.dispose);

    // 回合 1：只有流式正文 + idle，超时收尾后占位打 finalized 保留。
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: chunk(retainedTurn, channelId, sessionId, '半段回答')));
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(retainedTurn));
      return (row?['content'] as String? ?? '').contains('半段回答');
    });
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: state('idle', retainedTurn, channelId, sessionId)));
    await until(() => isFinalized(retainedTurn));
    expect(await db.getMessageById(liveTurnPlaceholderId(retainedTurn)),
        isNotNull);

    // 回合 2：新 turnId 开始输出，随后它自己的最终回复到达。
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9', data: chunk(newTurn, channelId, sessionId, '新答案')));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(newTurn)) != null);
    incoming.add(PeerControlEvent(
      peerId: 'peer-r9',
      data: created(2, channelId, sessionId, finalId, metadata: {
        'flow': {'run_id': 'r9run'},
      }),
    ));
    await until(() async => await db.getMessageById(finalId) != null);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(await db.getMessageById(finalId), isNotNull);
    expect(await db.getMessageById(liveTurnPlaceholderId(newTurn)), isNull,
        reason: '本回合的占位要被最终回复收掉');
    final retained =
        await db.getMessageById(liveTurnPlaceholderId(retainedTurn));
    expect(retained, isNotNull, reason: '别的失败回合保留的半段回答不能被这条最终回复删掉');
    expect(retained!['content'] as String? ?? '', contains('半段回答'));
    await incoming.close();
  });

  test('A9-4: 重登后的无关消息不删 DB 里带 finalized 的占位', () async {
    const sessionId = 'flow_r9_a94_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-r9-a94-old';
    const unrelatedId = 'msg-r9-a94-unrelated';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(unrelatedId);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final first = clientFor(incoming.stream,
        idle: const Duration(milliseconds: 40), fingerprint: 'fp-r9-a94');
    first.start();
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: chunk(turnId, channelId, sessionId, '重登前的半段')));
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('重登前的半段');
    });
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9', data: state('idle', turnId, channelId, sessionId)));
    await until(() => isFinalized(turnId));
    await first.dispose();

    // 模拟重登：全新的 client，内存集合全空，只有 DB 行上的 finalized 标记。
    final second = clientFor(incoming.stream, fingerprint: 'fp-r9-a94');
    second.start();
    addTearDown(second.dispose);
    incoming.add(PeerControlEvent(
      peerId: 'peer-r9',
      data: created(2, channelId, sessionId, unrelatedId),
    ));
    await until(() async => await db.getMessageById(unrelatedId) != null);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final retained = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(retained, isNotNull, reason: '重登后第一条无关 agent 消息不能删掉保留的半段回答');
    expect(retained!['content'] as String? ?? '', contains('重登前的半段'));
    expect(await isFinalized(turnId), isTrue);
    await incoming.close();
  });

  test('A9-5: 复用 turn_id 的瞬态重试，running + chunk 仍能显示', () async {
    const sessionId = 'flow_r9_a95_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-r9-a95-retry';
    const finalId = 'msg-r9-a95-final';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(finalId);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        idle: const Duration(seconds: 5), fingerprint: 'fp-r9-a95');
    client.start();
    addTearDown(client.dispose);

    // 第一次尝试：正文 → 最终回复，占位被删、turnId 进 settled。
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9', data: chunk(turnId, channelId, sessionId, '第一版')));
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('第一版');
    });
    incoming.add(PeerControlEvent(
      peerId: 'peer-r9',
      data: created(2, channelId, sessionId, finalId, metadata: {
        'flow': {'run_id': 'r9run'},
      }),
    ));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnId)) == null);

    // 主机瞬态重试：重放 running，turn_id 不变，然后接着出字。
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: state('running', turnId, channelId, sessionId,
            revision: 3, epoch: '2')));
    incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: chunk(turnId, channelId, sessionId, '重试后的答案')));
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('重试后的答案');
    });
    final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(row!['metadata'] as String? ?? '', contains('streaming'),
        reason: '重试的占位不能还挂着 finalized 标记');
    await incoming.close();
  });

  test('A9-6: attached DM 只有 metadata 的长工具回合不被兜底收尾', () async {
    const channelId = 'dm_r9_a96_attached';
    const agentId = 'agent-r9-a96';
    const turnId = 'turn-r9-a96';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'A96',
        type: 'dm',
        memberIds: const ['user', agentId],
        isPrivate: true,
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        idle: const Duration(milliseconds: 60),
        fallback: const Duration(milliseconds: 600),
        fingerprint: 'fp-r9-a96');
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-r9',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {'turn_id': turnId},
        },
      },
    ));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnId)) != null);

    Map<String, dynamic> event(String kind, {String? piece}) => {
          'type': 'pouch_turn_event',
          'request_id': turnId,
          'kind': kind,
          if (piece != null) 'chunk': piece,
          if (kind == 'metadata') 'metadata': {'kind': 'thinking'},
        };

    // 工具调用期间只有 metadata：累计时长超过兜底窗口，但每帧都在刷新它。
    // 用 debugFinalizeTimerArms 直接数「刷新」次数，不靠墙钟判定（并行跑
    // 几十个测试文件时 40ms 的 Future.delayed 会被拉长）。
    final armsAtStart = client.debugFinalizeTimerArms;
    for (var i = 0; i < 14; i++) {
      incoming
          .add(PeerControlEvent(peerId: 'peer-r9', data: event('metadata')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await until(() async => client.debugFinalizeTimerArms >= armsAtStart + 14);
    expect(
        client.debugFinalizeTimerArms, greaterThanOrEqualTo(armsAtStart + 14),
        reason: 'attached 回合的 metadata 帧必须刷新兜底收尾窗口');
    expect(client.debugHasFinalizeTimer(turnId), isTrue,
        reason: 'metadata 也要刷新兜底计时器，不能让它在工具调用中途收尾');

    incoming.add(PeerControlEvent(
        peerId: 'peer-r9', data: event('chunk', piece: '工具后的正文')));
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('工具后的正文');
    });
    expect((await db.getMessageById(liveTurnPlaceholderId(turnId)))!['content'],
        contains('工具后的正文'));

    // done 仍能正常关卡。
    incoming.add(PeerControlEvent(peerId: 'peer-r9', data: event('done')));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNotNull);
    await incoming.close();
  });

  test('A9-9: 普通 DM 长历史重放不按频道扫占位', () async {
    const channelId = 'dm_r9_a99_replay';
    const sessionId = 'dm_r9_a99_replay';
    final db = getIt<LocalDatabaseService>();
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream, fingerprint: 'fp-r9-a99');
    client.start();
    addTearDown(client.dispose);
    client.debugLivePlaceholderScans = 0;

    for (var seq = 1; seq <= 30; seq++) {
      final id = 'msg-r9-a99-$seq';
      await db.deleteMessage(id);
      incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: created(seq, channelId, sessionId, id),
      ));
    }
    await until(() async => await db.getMessageById('msg-r9-a99-30') != null);
    expect(client.debugLivePlaceholderScans, 0,
        reason: '普通 DM 频道没登记过 live/finalized 占位，不该每条消息全表扫');
    expect(await db.listLiveTurnPlaceholderIds(channelId), isEmpty);
    await incoming.close();
  });

  test('A9-10: 大量 chunk 不重建收尾 Timer', () async {
    const sessionId = 'flow_r9_a910_impl';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-r9-a910-timers';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        fallback: const Duration(seconds: 20), fingerprint: 'fp-r9-a910');
    client.start();
    addTearDown(client.dispose);

    for (var i = 0; i < 60; i++) {
      incoming.add(PeerControlEvent(
        peerId: 'peer-r9',
        data: chunk(turnId, channelId, sessionId, '片$i'),
      ));
    }
    await until(() async => client.debugFinalizeTimerArms >= 60);
    expect(client.debugFinalizeTimerAllocations, 1,
        reason: '60 片 chunk 只该有一个盯 deadline 的 Timer');
    expect(client.debugHasFinalizeTimer(turnId), isTrue);
    expect(liveTurnPlaceholderPrefix, 'hub-live-');
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['content'] as String? ?? '').contains('片59');
    });
    await incoming.close();
  });
}
