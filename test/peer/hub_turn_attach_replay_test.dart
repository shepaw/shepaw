import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 群编排回合里 She 自己的提问（`ask_ui`）走的是另一条路：它不进 ApprovalBus，
/// 只在生成那一刻 `send` 一次，而宿主还在 `ask_ui` 里等回答（30 分钟）。
/// 手机那一刻不在线，这张卡就没了 —— 宿主那半小时白等，用户连「被问过」都
/// 不知道。
///
/// 宿主现在把卡片和等待一起留着（`PhoneState::pending_interaction_for_turn`），
/// 手机重连后 `turn_attach_req` 续传这个回合时会补发回来。app 必须把它渲染成
/// 卡片，否则补发等于没补。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    // 渲染卡片走 getIt<LocalDatabaseService>()（生产路径如此）。
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  /// 这几步里有真异步（写库、订阅分发），pumpEventQueue 只推微任务，等不到。
  Future<void> until(FutureOr<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  Future<List<Map<String, dynamic>>> rowsIn(
    LocalDatabaseService db,
    String channelId,
  ) => db.getChannelMessages(channelId, limit: 50);

  test('续传补发的交互卡会被渲染出来', () async {
    final db = LocalDatabaseService();
    final channelId = 'dm_replay_${DateTime.now().microsecondsSinceEpoch}';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Replay',
        type: 'dm',
        memberIds: const ['user', 'she'],
        isPrivate: true,
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        return true;
      },
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(() async {
      await client.dispose();
      await incoming.close();
    });

    // 回合开跑（手机重连后从事件日志里补到的 turn.started）：挂上它、请求续传。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': channelId,
          'agent_id': 'she',
          'data': {'turn_id': 'turn-replay', 'channel_id': channelId},
        },
      },
    ));
    await until(() => sent.any((frame) => frame['type'] == 'turn_attach_req'));

    // 续传回来的那一帧就是没人看见的卡片。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'pouch_turn_event',
        'request_id': 'turn-replay',
        'kind': 'interaction',
        'interaction_id': 'ix-replay',
        'agent_id': 'she-builtin-agent-001',
        'interaction_type': 'action_confirmation',
        'data': {
          'confirmation_id': 'ix-replay',
          'interaction_id': 'ix-replay',
          'prompt': '允许执行 rm -rf build？',
          'actions': [
            {'id': 'allow', 'label': 'Allow', 'style': 'primary'},
            {'id': 'deny', 'label': 'Deny', 'style': 'danger'},
          ],
        },
      },
    ));
    await until(
      () async => (await rowsIn(db, channelId))
          .any((row) => row['id'] == 'hub-ix-ix-replay'),
    );

    final rows = await rowsIn(db, channelId);
    final card = rows.where((row) => row['id'] == 'hub-ix-ix-replay').toList();
    expect(
      card,
      hasLength(1),
      reason: '补发的卡片没渲染出来 —— 用户根本没机会回答，宿主白等 30 分钟',
    );
    final metadata =
        jsonDecode(card.single['metadata'] as String) as Map<String, dynamic>;
    final hub = metadata['hub_interaction'] as Map<String, dynamic>;
    expect(hub['interaction_id'], 'ix-replay');
    expect(hub['host_peer_id'], 'peer-1');
    // 作答靠这张卡的 action_confirmation 元数据（confirmation_id = ix-replay）。
    final ac = metadata['action_confirmation'] as Map<String, dynamic>;
    expect(ac['confirmation_id'], 'ix-replay');
  });

  test('会话不明的补发卡片不渲染（拿不到频道就没地方放）', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(() async {
      await client.dispose();
      await incoming.close();
    });

    // 没挂过这个 turn（没有 turn.started），卡片只能丢 —— 但必须安静，不能炸。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'pouch_turn_event',
        'request_id': 'turn-unknown',
        'kind': 'interaction',
        'interaction_id': 'ix-unknown',
        'interaction_type': 'action_confirmation',
        'data': {'confirmation_id': 'ix-unknown'},
      },
    ));
    await pumpEventQueue();

    final db = LocalDatabaseService();
    final rows = await db.getChannelMessages('dm_never', limit: 50);
    expect(rows, isEmpty);
  });
}
