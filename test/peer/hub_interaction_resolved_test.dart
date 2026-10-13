import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 主机说一个交互结束了，会写 `interaction.resolved`（别处作答、等不到回答、
/// 回合取消、主机重启）。这条以前只被当成一条通知丢掉，卡片就一直可点。
///
/// 可点是骗人的：`PhoneState` 里记录已摘，再点 `pouch_interaction_resp` 到了
/// 主机直接被扔（`complete_interaction` 返回 false），而本地照样把用户的选择
/// 记成已生效 —— 看着答上了，其实没算。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  /// 写库和订阅分发都是真异步，pumpEventQueue 推不动它们。
  Future<void> until(FutureOr<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  late LocalDatabaseService db;
  late StreamController<PeerControlEvent> incoming;
  late HubEventClient client;
  var seq = 0;
  var ixSeq = 0;

  /// 库是单例、测试之间共享，交互 id 撞了就会读到上一场留下的卡片。
  String nextIx() => 'ix-${DateTime.now().microsecondsSinceEpoch}-${++ixSeq}';

  String cardId(String interactionId) => HubEventClient.hubCardMessageId(interactionId);

  Future<String> newChannel() async {
    final id = 'dm_resolved_${DateTime.now().microsecondsSinceEpoch}';
    await db.createChannel(
      Channel.withMemberIds(
        id: id,
        name: 'Resolved',
        type: 'dm',
        memberIds: const ['user', 'she'],
        isPrivate: true,
      ),
      'user',
    );
    return id;
  }

  /// 渲染一张交互卡（走 hub 的 `interaction.pending`，和线上一样），返回交互 id。
  Future<String> renderCard(
    String channelId, {
    String kind = 'action_confirmation',
    Map<String, dynamic> data = const {'prompt': '允许执行 rm -rf build？'},
    String turnId = 'turn-1',
  }) async {
    final interactionId = nextIx();
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': ++seq,
          'kind': 'interaction.pending',
          'channel_id': channelId,
          'agent_id': 'she',
          'data': {
            'interaction_id': interactionId,
            'turn_id': turnId,
            'agent_id': 'she',
            'interaction_type': kind,
            'data': {
              ...data,
              'confirmation_id': interactionId,
              'interaction_id': interactionId,
            },
          },
        },
      },
    ));
    await until(() async => await db.getMessageById(cardId(interactionId)) != null);
    return interactionId;
  }

  /// 回合结束。正常顺序下主机先发 `interaction.resolved` 再结束回合，
  /// 这里不发 resolved —— 测的就是那帧没到手时的兜底。
  Future<void> finishTurn(String turnId) async {
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': ++seq,
          'kind': 'turn.finished',
          'channel_id': '',
          'agent_id': 'she',
          'data': {'turn_id': turnId},
        },
      },
    ));
  }

  Future<void> resolve(String interactionId, String by) async {
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': ++seq,
          'kind': 'interaction.resolved',
          'channel_id': '',
          'agent_id': '',
          'data': {'interaction_id': interactionId, 'by': by},
        },
      },
    ));
  }

  /// 卡片里那层载荷（`action_confirmation` / `form`）。
  Future<Map<String, dynamic>> cardPayload(String messageId, String kind) async {
    final row = await db.getMessageById(messageId);
    final metadata =
        jsonDecode(row!['metadata'] as String) as Map<String, dynamic>;
    return Map<String, dynamic>.from(metadata[kind] as Map);
  }

  Future<void> seedAnswer(String messageId, String kind, String key, Object value) async {
    final row = await db.getMessageById(messageId);
    final metadata =
        jsonDecode(row!['metadata'] as String) as Map<String, dynamic>;
    metadata[kind] = Map<String, dynamic>.from(metadata[kind] as Map)..[key] = value;
    await db.updateMessageMetadata(messageId, metadata);
  }

  setUp(() async {
    db = LocalDatabaseService();
    seq = 0;
    incoming = StreamController<PeerControlEvent>.broadcast();
    client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
  });

  tearDown(() async {
    await client.dispose();
    await incoming.close();
  });

  test('超时作废：卡片收起可点态，理由跟着主机的说法', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);

    await resolve(ix, 'timeout');

    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    final payload = await cardPayload(cardId(ix), 'action_confirmation');
    expect(payload['closed'], 'timeout');
    // 卡片本身留着 ——「问过但没答」这个事实值得留在对话里。
    expect(await db.getMessageById(cardId(ix)), isNotNull);
  });

  test('主机重启时悬着的卡片也收起来', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);

    await resolve(ix, 'hub_restart');

    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    // 主机重启 = 这个回合没了，按「回合已结束」说。
    expect(
      (await cardPayload(cardId(ix), 'action_confirmation'))['closed'],
      'turn_ended',
    );
  });

  test('别处作答：理由说的是别处，不是一个莫名的超时', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);

    // `by` 是一个 peer id，也就是有设备答了（可能是另一台）。
    await resolve(ix, 'peer-9f3a');

    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    expect(
      (await cardPayload(cardId(ix), 'action_confirmation'))['closed'],
      'answered_elsewhere',
    );
  });

  test('自己答过的卡片不被随后到的作废帧盖掉', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);
    // 本地先记下裁决（用户点完，主机才广播 resolved）。
    await seedAnswer(cardId(ix), 'action_confirmation', 'selected_action_id', 'allow');

    await resolve(ix, 'peer-9f3a');

    // 给事件足够的时间落地，再确认它没动过裁决。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final payload = await cardPayload(cardId(ix), 'action_confirmation');
    expect(payload['selected_action_id'], 'allow');
    expect(payload['closed'], isNull, reason: '自己答的卡不该被说成「已在别处作答」');
  });

  // 四种卡的裁决键各不相同（审批 `selected_action_id`、单选
  // `selected_option_id`、多选 `selected_option_ids`、表单 `submitted_values`）。
  // 只认审批那一种时，用户刚点完的单选 / 多选卡会被随后到的作废帧说成
  // 「已在别处作答」。
  test('自己答过的单选卡不被作废帧盖掉', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId, kind: 'single_select', data: {
      'prompt': '保留哪个 agent？',
      'options': [
        {'label': 'claude-code', 'value': 'aa99befe'},
        {'label': 'cursor', 'value': 'f729b795'},
      ],
    });
    await seedAnswer(cardId(ix), 'single_select', 'selected_option_id', 'f729b795');

    await resolve(ix, 'peer-9f3a');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final payload = await cardPayload(cardId(ix), 'single_select');
    expect(payload['selected_option_id'], 'f729b795');
    expect(payload['closed'], isNull, reason: '自己答的卡不该被说成「已在别处作答」');
  });

  test('自己答过的多选卡不被作废帧盖掉', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId, kind: 'multi_select', data: {
      'prompt': '要开哪些？',
      'options': [
        {'label': 'Alpha', 'value': 'alpha'},
        {'label': 'Beta', 'value': 'beta'},
      ],
    });
    await seedAnswer(cardId(ix), 'multi_select', 'selected_option_ids', ['beta']);

    await resolve(ix, 'peer-9f3a');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final payload = await cardPayload(cardId(ix), 'multi_select');
    expect(payload['selected_option_ids'], ['beta']);
    expect(payload['closed'], isNull, reason: '自己答的卡不该被说成「已在别处作答」');
  });

  test('没人答过的单选卡照旧收起', () async {
    // 上面两条是「别管太宽」，这条确认作废本身还生效。
    final channelId = await newChannel();
    final ix = await renderCard(channelId, kind: 'single_select', data: {
      'prompt': '保留哪个 agent？',
      'options': [
        {'label': 'claude-code', 'value': 'aa99befe'},
      ],
    });

    await resolve(ix, 'timeout');

    await until(() async =>
        (await cardPayload(cardId(ix), 'single_select'))['closed'] != null);
    expect((await cardPayload(cardId(ix), 'single_select'))['closed'], 'timeout');
  });

  test('表单卡走同一套：提交过的不动，没提交的收起来', () async {
    final channelId = await newChannel();
    const form = {
      'title': '报个参数',
      'fields': [
        {'name': 'target', 'label': '目标', 'type': 'text'},
      ],
    };
    final pending = await renderCard(channelId, kind: 'form', data: form);

    await resolve(pending, 'timeout');
    await until(() async => (await cardPayload(cardId(pending), 'form'))['closed'] != null);
    expect((await cardPayload(cardId(pending), 'form'))['closed'], 'timeout');

    // 另一张：用户已经填过并提交了。
    final submitted = await renderCard(channelId, kind: 'form', data: form);
    await seedAnswer(cardId(submitted), 'form', 'submitted_values', {'target': 'x'});

    await resolve(submitted, 'timeout');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await cardPayload(cardId(submitted), 'form'))['closed'], isNull);
  });

  test('本地没有这张卡时安静放过', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);

    // 别的回合的交互，本机从没渲染过。
    await resolve('ix-never-seen', 'timeout');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await cardPayload(cardId(ix), 'action_confirmation'))['closed'], isNull);
    expect(await db.getMessageById(cardId('ix-never-seen')), isNull);
  });

  test('重复的作废帧不覆盖先到的理由', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId);

    await resolve(ix, 'timeout');
    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    await resolve(ix, 'peer-9f3a');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      (await cardPayload(cardId(ix), 'action_confirmation'))['closed'],
      'timeout',
    );
  });

  test('回合结束时兜底：作废帧没到手也不留一张能点的卡', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId, turnId: 'turn-A');

    await finishTurn('turn-A');

    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    expect(
      (await cardPayload(cardId(ix), 'action_confirmation'))['closed'],
      'turn_ended',
    );
  });

  test('兜底只收这个回合的卡，别的回合不动', () async {
    final channelId = await newChannel();
    final mine = await renderCard(channelId, turnId: 'turn-A');
    final other = await renderCard(channelId, turnId: 'turn-B');

    await finishTurn('turn-A');

    await until(() async => (await cardPayload(cardId(mine), 'action_confirmation'))['closed'] != null);
    final untouched = await cardPayload(cardId(other), 'action_confirmation');
    expect(untouched['closed'], isNull, reason: '另一个回合还在等回答，卡片得留着能点');
  });

  test('兜底不碰已经答过的卡片', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId, turnId: 'turn-A');
    await seedAnswer(cardId(ix), 'action_confirmation', 'selected_action_id', 'allow');

    await finishTurn('turn-A');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final payload = await cardPayload(cardId(ix), 'action_confirmation');
    expect(payload['selected_action_id'], 'allow');
    expect(payload['closed'], isNull);
  });

  test('兜底不重复干活：同一个回合结束两次也只作废一次', () async {
    final channelId = await newChannel();
    final ix = await renderCard(channelId, turnId: 'turn-A');

    await finishTurn('turn-A');
    await until(() async => (await cardPayload(cardId(ix), 'action_confirmation'))['closed'] != null);
    await finishTurn('turn-A');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      (await cardPayload(cardId(ix), 'action_confirmation'))['closed'],
      'turn_ended',
    );
  });
}
