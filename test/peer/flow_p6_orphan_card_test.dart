import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart'
    show
        PeerAgentClientService,
        hostSessionIdForChannel,
        isFlowFormCard,
        syncedPeerChannelId;
import 'package:shepaw/peer/services/peer_agent_ids.dart'
    show orphanCardBelongsToHostSession;
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/approval/pending_approval_hub.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/models/channel.dart';

import '../storage/test_harness.dart';

/// P6 App 半边：群外工作流发起的 `agent_form_req` 没有本地 `_pending`，走孤儿卡
/// 那条路。帧里的 `channel_id` 是裸主机会话 id（`flow_<rid8>_she` /
/// `flow_<rid8>_<node>`），App 要把它落到本机 `psess_<id>` 频道，并且即使频道
/// 还没被 `message.created` 同步下来（离线只重放 deferred 帧）也要先建好壳，
/// 否则消息行没有会话行、横幅/通知点开会落进空频道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  final svc = PeerAgentClientService.instance;
  var seq = 0;

  // 每个用例一条独立会话：孤儿卡缓存 / PendingApprovalHub 是进程级的。
  String nextTag() => 'p6${(seq++).toRadixString(16)}';
  String nextApprovalId(String kind) =>
      '$kind-${nextTag()}-${DateTime.now().microsecondsSinceEpoch}';

  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    db = getIt<LocalDatabaseService>();
    await db.database;
  });

  tearDown(() {
    svc.debugSendControlOverride = null;
    PendingApprovalHub.instance.resetForTest();
  });

  Future<void> until(FutureOr<bool> Function() ready) async {
    for (var i = 0; i < 300; i++) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  Map<String, dynamic> metadataOf(Map<String, dynamic> row) =>
      Map<String, dynamic>.from(jsonDecode(row['metadata'] as String) as Map);

  Map<String, dynamic> formFrame({
    required String approvalId,
    required String channelId,
    String agentId = 'she-builtin-agent-001',
  }) =>
      {
        'request_id': approvalId,
        'approval_id': approvalId,
        'agent_id': agentId,
        'channel_id': channelId,
        'title': '工作流 · 需要你确认',
        'fields': [
          {
            'type': 'single_select',
            'field_id': 'question_0',
            'label': '继续吗',
            'options': [
              {'id': '通过', 'label': '通过'},
              {'id': '返工', 'label': '返工'},
            ],
          },
        ],
      };

  group('P6 孤儿卡落点', () {
    test('gate 卡 channel_id=flow_<rid8>_she 落到 psess_ 频道并建好壳（未同步）', () async {
      final sessionId = 'flow_${nextTag()}_she';
      final channelId = syncedPeerChannelId(sessionId);
      await db.deleteChannel(channelId);
      expect(await db.getChannelById(channelId), isNull, reason: '先模拟频道还没同步下来');

      final approvalId = nextApprovalId('flowgate');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(approvalId: approvalId, channelId: sessionId),
        peerId: 'peer-1',
      );

      final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
      await until(() async => await db.getMessageById(cardId) != null);
      final row = (await db.getMessageById(cardId))!;
      expect(row['channel_id'], channelId);
      final form = metadataOf(row)['form'] as Map;
      expect(form['form_id'], approvalId);
      expect(
          form['peer_form'], {'peer_id': 'peer-1', 'approval_id': approvalId});

      // 离线补发没有 message.created，ensureFlowSessionShell 必须补上会话行。
      await until(() async => await db.getChannelById(channelId) != null);
      expect(await db.getChannelById(channelId), isNotNull);
      final members = await db.getChannelMemberIds(channelId);
      expect(members, contains('user'));

      // 横幅 / 通知按这个本机频道路由（点开就直接进这条 psess_ 会话）。
      expect(PendingApprovalHub.instance.countForChannel(channelId), 1);
    });

    test('节点 ask_user 卡 channel_id=flow_<rid8>_<node> 落到对应 psess_ 频道',
        () async {
      final sessionId = 'flow_${nextTag()}_impl';
      final channelId = syncedPeerChannelId(sessionId);
      await db.deleteChannel(channelId);

      final approvalId = nextApprovalId('ask');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(
          approvalId: approvalId,
          channelId: sessionId,
          agentId: 'agent-7',
        ),
        peerId: 'peer-1',
      );

      final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
      await until(() async => await db.getMessageById(cardId) != null);
      expect((await db.getMessageById(cardId))!['channel_id'], channelId);
      await until(() async => await db.getChannelById(channelId) != null);
      expect(await db.getChannelById(channelId), isNotNull);

      // 聊天页后开时按 hostSessionId 补投：只补本会话的卡。
      final events = svc.pendingOrphanFormsFor(
        peerId: 'peer-1',
        remoteAgentId: 'agent-7',
        hostChannelId: sessionId,
      );
      expect(events.map((e) => e['form_id']), contains(approvalId));
      expect(
        svc
            .pendingOrphanFormsFor(
              peerId: 'peer-1',
              remoteAgentId: 'agent-7',
              hostChannelId: 'flow_other_she',
            )
            .map((e) => e['form_id']),
        isNot(contains(approvalId)),
      );
    });

    test('deferred 重放帧也按 channel_id 落到正确的 psess_ 频道', () async {
      final sessionId = 'flow_${nextTag()}_she';
      final channelId = syncedPeerChannelId(sessionId);
      await db.deleteChannel(channelId);

      final approvalId = nextApprovalId('flowgate');
      final frame = {
        ...formFrame(approvalId: approvalId, channelId: sessionId),
        'deferred': true,
      };
      svc.debugInjectControlForTest('agent_form_deferred', frame,
          peerId: 'peer-1');

      final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
      await until(() async => await db.getMessageById(cardId) != null);
      expect((await db.getMessageById(cardId))!['channel_id'], channelId);
      await until(() async => await db.getChannelById(channelId) != null);
    });

    test('普通 DM 的 ask_user 卡仍落在原频道，不建 psess_ 壳（回归）', () async {
      final channelId = 'dm_p6_${nextTag()}';
      await db.createChannel(
        Channel.withMemberIds(
          id: channelId,
          name: 'DM',
          type: 'dm',
          memberIds: const ['user', 'remote-agent'],
          isPrivate: true,
        ),
        'user',
      );

      final approvalId = nextApprovalId('dm');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(
          approvalId: approvalId,
          channelId: channelId,
          agentId: 'remote-agent',
        ),
        peerId: 'peer-1',
      );

      final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
      await until(() async => await db.getMessageById(cardId) != null);
      expect((await db.getMessageById(cardId))!['channel_id'], channelId);
      // 普通 DM 不该被误判成 flow 会话而另建一个 psess_ 壳。
      expect(await db.getChannelById(syncedPeerChannelId(channelId)), isNull);
      expect(PendingApprovalHub.instance.countForChannel(channelId), 1);
    });

    test('落库后的 flow 卡仍然答得出去（agent_form_resp 不过期）', () async {
      final sessionId = 'flow_${nextTag()}_she';
      final approvalId = nextApprovalId('flowgate');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(approvalId: approvalId, channelId: sessionId),
        peerId: 'peer-1',
      );
      await until(() async =>
          await db.getMessageById(
              PeerApprovalPayload.formCardMessageId(approvalId)) !=
          null);

      // 没有真连接，发送必然失败；关键是没越过「不认识这张卡」的守卫。
      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'question_0': '通过'},
        ),
        throwsA(isNot(isA<PeerApprovalExpiredException>())),
      );
    });
  });

  group('P6 认领口径（裸 channel_id ↔ psess_ 频道）', () {
    test('flow_<rid8>_she / flow_<rid8>_<node> 都能被对应 psess_ 会话认领', () {
      for (final sessionId in [
        'flow_deadbe12_she',
        'flow_deadbe12_impl',
        'flow_deadbe12_agent_default',
      ]) {
        final channelId = syncedPeerChannelId(sessionId);
        expect(hostSessionIdForChannel(channelId), sessionId);
        expect(
          orphanCardBelongsToHostSession(
              sessionId, hostSessionIdForChannel(channelId)),
          isTrue,
        );
      }
    });

    test('别的会话的卡不认领', () {
      expect(
        orphanCardBelongsToHostSession(
          'flow_deadbe12_she',
          hostSessionIdForChannel('psess_flow_cafe9999_she'),
        ),
        isFalse,
      );
      expect(orphanCardBelongsToHostSession('', 'flow_deadbe12_she'), isFalse);
    });

    test('普通 DM 频道仍按原 id 精确匹配', () {
      expect(
        orphanCardBelongsToHostSession(
          'dm_remote-agent_user_1',
          hostSessionIdForChannel('dm_remote-agent_user_1'),
        ),
        isTrue,
      );
    });
  });

  group('P6 ChatController 实际认领', () {
    Future<ChatController> controllerFor(String channelId) async {
      final c = ChatController(
        agentId: 'she-builtin-agent-001',
        initialAgentName: '惜宝',
        initialChannelId: channelId,
        getUserId: () => 'user-1',
        getUserName: () => 'User',
      );
      c.currentChannelId = channelId;
      c.installOrphanCardListenersForTest();
      return c;
    }

    test('打开的 psess_flow_…_she 会话认领裸 channel_id 的孤儿卡', () async {
      final sessionId = 'flow_${nextTag()}_she';
      final channelId = syncedPeerChannelId(sessionId);
      final c = await controllerFor(channelId);
      addTearDown(c.dispose);

      final approvalId = nextApprovalId('claim');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(approvalId: approvalId, channelId: sessionId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(c.messages, isNotEmpty,
          reason: '裸主机会话 id 与 psess_ 频道是同一条会话，不该因字符串不等丢卡');
    });

    test('别的 flow 会话的卡不进当前列表', () async {
      final channelId = syncedPeerChannelId('flow_${nextTag()}_she');
      final c = await controllerFor(channelId);
      addTearDown(c.dispose);

      final approvalId = nextApprovalId('other');
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(
          approvalId: approvalId,
          channelId: 'flow_${nextTag()}_impl',
        ),
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(c.messages, isEmpty);
    });
  });

  group('P6 deferred 补跑抑制', () {
    test('节点会话里普通 DM 的延期卡不能靠当前会话兜底成流程卡', () async {
      // 卡片落在节点会话里（psess_flow_…），但它是普通 DM 的 ask 卡：metadata
      // 里的 channel_id 已被剥掉，只剩 request_id / approval_id = ask-…
      final c = ChatController(
        agentId: 'she-builtin-agent-001',
        initialAgentName: '惜宝',
        initialChannelId: syncedPeerChannelId('flow_${nextTag()}_impl'),
        getUserId: () => 'user-1',
        getUserName: () => 'User',
      );
      addTearDown(c.dispose);
      c.currentChannelId = syncedPeerChannelId('flow_${nextTag()}_impl');

      expect(
        c.shouldSkipDeferredFormFollowUp(
          {'form_id': 'ask-dm', 'request_id': 'ask-dm'},
          'ask-dm',
        ),
        isFalse,
        reason: '当前会话是 flow_ 也不能把普通 DM 的 ask 卡当成工作流卡',
      );
      // 真正的 flow 卡仍要跳过（由主机推进）。
      expect(
        c.shouldSkipDeferredFormFollowUp(
          {'request_id': 'flow-r1-impl-a1'},
          'ask-xyz',
        ),
        isTrue,
      );
      expect(
        c.shouldSkipDeferredFormFollowUp(
          {'approval_id': 'flowgate-r1-ok'},
          'flowgate-r1-ok',
        ),
        isTrue,
      );
      expect(
        c.shouldSkipDeferredFormFollowUp(null, 'ask-dm'),
        isFalse,
      );
    });

    test('gate / 节点 flow 卡不能补开新回合', () {
      expect(
        isFlowFormCard(channelId: 'flow_deadbe12_she'),
        isTrue,
      );
      expect(
        isFlowFormCard(approvalId: 'flowgate-r1-ok'),
        isTrue,
      );
      expect(
        isFlowFormCard(requestId: 'flow-r1-impl-a1'),
        isTrue,
      );
      // 卡片落库时 channel_id 被剥掉，仍靠 request_id / approval_id 认得出。
      expect(
        isFlowFormCard(
          requestId: 'flow-deadbe12-impl-a2',
          approvalId: 'ask-xyz',
        ),
        isTrue,
      );
      expect(
        isFlowFormCard(
          channelId: 'psess_flow_deadbe12_impl',
          requestId: 'dm-1',
          approvalId: 'appr-dm-1',
        ),
        isFalse,
      );
    });

    test('普通 DM 卡照旧补那一轮', () {
      expect(
        isFlowFormCard(
          channelId: 'dm_remote-agent_user_1',
          requestId: 'req-1',
          approvalId: 'appr-1',
        ),
        isFalse,
      );
      expect(isFlowFormCard(), isFalse);
      expect(isFlowFormCard(channelId: '  flow_x  '), isTrue);
    });
  });

  group('P6 状态 / 运行会话 id 解析', () {
    test('waiting_user / waiting / needs_user 都归到 waitingUser', () {
      for (final raw in ['waiting_user', 'waiting', 'needs_user']) {
        expect(FlowNodeStatus.parse(raw), FlowNodeStatus.waitingUser);
      }
      expect(FlowNodeStatus.waitingUser.isWaitingForUser, isTrue);
      expect(FlowNodeStatus.waitingUser.isTerminal, isFalse);
    });

    test('A7-6: halted 是终态失败，不算等人回答', () {
      expect(FlowNodeStatus.parse('halted'), FlowNodeStatus.halted);
      expect(FlowNodeStatus.halted.isWaitingForUser, isFalse,
          reason: '主机 Halted 没有自动卡片，不能给红点 / 去回答');
      expect(FlowNodeStatus.halted.isTerminal, isTrue,
          reason: '仍在 isTerminal 里');
      const node = FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.halted,
        sessionId: 'flow_deadbe12_impl',
      );
      expect(node.awaitsAnswer, isFalse);
    });

    test('未知状态返回 null 且不抛异常', () {
      expect(FlowNodeStatus.parse('some_future_status'), isNull);
      expect(FlowNodeStatus.parse(42), isNull);
      expect(FlowNodeStatus.parse(null), isNull);
      final node = FlowNode.fromJson({
        'key': 'a',
        'id': 'a',
        'kind': 'task',
        'status': 'brand_new_state',
      });
      expect(node.status, isNull);
      final run = FlowRunView.fromResponse({
        'success': true,
        'run_id': 'r1',
        'status': 'running',
        'tree': [
          {'key': 'a', 'id': 'a', 'kind': 'task', 'status': 'brand_new_state'},
        ],
      });
      expect(run, isNotNull);
      expect(run!.tree.single.status, isNull);
    });

    test('run 级 waiting 别名按 running 处理，不判加载失败', () {
      for (final raw in ['waiting_user', 'waiting', 'needs_user', 'halted']) {
        expect(FlowRunStatus.parse(raw), FlowRunStatus.running);
      }
      expect(
        FlowRunView.fromResponse({
          'success': true,
          'run_id': 'r1',
          'status': 'waiting_user',
          'tree': <dynamic>[],
        }),
        isNotNull,
      );
    });

    test('flowRunSheSessionId 从节点会话前缀推出运行级惜宝会话', () {
      final tree = [
        FlowNode(
          key: 'seq',
          id: 'seq',
          kind: 'seq',
          children: [
            FlowNode.fromJson({
              'key': 'seq/impl',
              'id': 'impl',
              'kind': 'task',
              'session_id': 'flow_deadbe12_impl',
              'agent_id': 'agent-7',
            }),
          ],
        ),
      ];
      expect(flowRunSheSessionId(tree), 'flow_deadbe12_she');
      expect(flowRunSheSessionId([]), isNull);
      // 群内节点会话带 group: 前缀时也能认出 rid8。
      expect(
        flowRunSheSessionId([
          FlowNode.fromJson({
            'key': 'n',
            'id': 'n',
            'kind': 'task',
            'session_id': 'group:g1:s1:flow_deadbe12_impl',
          }),
        ]),
        'flow_deadbe12_she',
      );
    });

    test('A6-11: 16 位十六进制 run_tag 也能推出运行级惜宝会话', () {
      // H6-10 把 tag 从 8 位改成完整 64 位十六进制；App 侧不能写死 8 位。
      for (final nodeSession in const [
        'flow_deadbe12_impl',
        'flow_deadbe12deadbe12_impl',
        'group:g1:s1:flow_deadbe12deadbe12_impl',
      ]) {
        final tag =
            RegExp(r'flow_([0-9a-fA-F]+)_').firstMatch(nodeSession)!.group(1)!;
        expect(
          flowRunSheSessionId([
            FlowNode.fromJson({
              'key': 'n',
              'id': 'n',
              'kind': 'task',
              'session_id': nodeSession,
            }),
          ]),
          'flow_${tag}_she',
        );
      }
    });

    test('FlowRunView 解析运行会话 id 并在状态更新后保留', () {
      final run = FlowRunView.fromResponse({
        'success': true,
        'run_id': 'r1',
        'status': 'running',
        'tree': [
          {
            'key': 'impl',
            'id': 'impl',
            'kind': 'task',
            'session_id': 'flow_deadbe12_impl',
          },
        ],
      })!;
      expect(run.runSessionId, 'flow_deadbe12_she');
      expect(
        run.withNodeStatus('impl', FlowNodeStatus.waitingUser, 2).runSessionId,
        'flow_deadbe12_she',
      );
      expect(
        run.withRunStatus(FlowRunStatus.succeeded).runSessionId,
        'flow_deadbe12_she',
      );
      // 主机显式下发 run 级字段时优先用它。
      expect(
        FlowRunView.fromResponse({
          'success': true,
          'run_id': 'r1',
          'status': 'running',
          'she_session_id': 'flow_explicit_she',
          'tree': <dynamic>[],
        })!
            .runSessionId,
        'flow_explicit_she',
      );
      // 主机标了群运行就不画运行会话入口（群内问题走群聊、没有惜宝会话）。
      expect(
        FlowRunView.fromResponse({
          'success': true,
          'run_id': 'r1',
          'status': 'running',
          'group_id': 'group-1',
          'tree': [
            {
              'key': 'impl',
              'id': 'impl',
              'kind': 'task',
              'session_id': 'flow_deadbe12_impl',
            },
          ],
        })!
            .runSessionId,
        isNull,
      );
    });
  });
}
