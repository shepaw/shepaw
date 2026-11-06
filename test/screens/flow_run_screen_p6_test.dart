import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/services/approval/pending_approval_hub.dart';
import 'package:shepaw/services/approval/pending_approval_item.dart';

/// P6：FlowRunScreen 顶部「运行会话」入口打开本次运行的惜宝会话
/// （`psess_flow_<rid8>_she`）；等用户回答的节点上「去回答」打开节点会话并
/// 带上待答卡片的高亮 id。关卡按钮保持原样可用。
const _tree = [
  {
    'key': 'impl',
    'id': 'impl',
    'kind': 'task',
    'status': 'waiting_user',
    'session_id': 'flow_deadbe12_impl',
    'agent_id': 'agent-7',
  },
  {
    'key': 'ok',
    'id': 'ok',
    'kind': 'gate',
    'status': 'running',
    'options': ['通过', '返工'],
  },
];

HubFlow _host(
  StreamController<PeerControlEvent> bus, {
  List<dynamic>? tree,
  void Function(String choice)? onAnswer,
  Map<String, dynamic>? extra,
}) =>
    HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_get_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'tasks_used': 1,
              'tree': tree ?? _tree,
              if (extra != null) ...extra,
            },
          ));
        } else if (frame['type'] == 'flow_gate_resp' && onAnswer != null) {
          // HubFlow.gateFrame 发的请求 type 就是 flow_gate_resp，回包同型。
          onAnswer(frame['choice'] as String? ?? '');
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_gate_resp',
              'request_id': frame['request_id'],
              'success': true,
            },
          ));
        }
        return true;
      },
    );

Widget _app(
  HubFlow client, {
  void Function(FlowNode node)? onOpenSession,
}) =>
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        client: client,
        onOpenSession: onOpenSession,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  final opened = <({String channelId, String? agentId})>[];

  setUp(() {
    opened.clear();
    debugLastFlowSessionHighlightMessageId = null;
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    PendingApprovalHub.instance.resetForTest();
  });

  tearDown(() {
    debugOpenFlowSessionChannel = null;
    debugLastFlowSessionHighlightMessageId = null;
    PendingApprovalHub.instance.resetForTest();
  });

  testWidgets('P6: 运行会话入口打开 psess_flow_<rid8>_she（从节点前缀推导）', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-run-session')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-run-session')));
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_she');
    expect(opened.single.agentId, 'she-builtin-agent-001');
    // 运行会话不带某张卡的高亮：它是流程层面的入口。
    expect(debugLastFlowSessionHighlightMessageId, isNull);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P6: 没有节点会话时不出「运行会话」入口（不瞎拼频道）', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      tree: const [
        {
          'key': 'ok',
          'id': 'ok',
          'kind': 'gate',
          'status': 'running',
          'options': ['通过'],
        },
      ],
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-run-session')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P6: 主机下发 she_session_id 时，节点还没跑过也能打开运行会话', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      tree: const [
        {
          'key': 'ok',
          'id': 'ok',
          'kind': 'gate',
          'status': 'running',
          'options': ['通过'],
        },
      ],
      extra: const {'she_session_id': 'flow_5a5a1234_she'},
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-run-session')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-run-session')));
    await _settle(tester);
    expect(opened.single.channelId, 'psess_flow_5a5a1234_she');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P6: 主机下发 group_id 时群运行收起「运行会话」入口', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      extra: const {
        'group_id': 'g1',
        'she_session_id': 'flow_5a5a1234_she',
      },
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-run-session')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P6: 去回答打开节点会话并带上待答卡片的高亮 id', (tester) async {
    const channelId = 'psess_flow_deadbe12_impl';
    const formId = 'ask-run1-impl';
    PendingApprovalHub.instance.upsert(const PendingApprovalItem(
      id: 'action:$formId',
      channelId: channelId,
      agentId: 'agent-7',
      agentName: 'Agent',
      kind: PendingApprovalKind.action,
      createdAt: 1,
    ));

    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-node-goto-answer-impl')));
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.channelId, channelId);
    expect(opened.single.agentId, 'agent-7');
    expect(debugLastFlowSessionHighlightMessageId,
        PeerApprovalPayload.formCardMessageId(formId));
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('A6-5: 节点事件带 agent_id，重拉之前点会话入口就有成员', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      tree: const [
        {
          'key': 'impl',
          'id': 'impl',
          'kind': 'task',
          'status': 'waiting_user',
          // 初始树还没拿到执行 agent（主机节点事件先到、重拉 400ms 后才到）。
          'session_id': 'flow_deadbe12_impl',
        },
      ],
    )));
    await _settle(tester);

    bus.add(PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'flow.node.changed',
        'run_id': 'r1',
        'node': 'impl',
        'status': 'waiting_user',
        'session_id': 'flow_deadbe12_impl',
        'agent_id': 'agent-live',
        'attempt': 1,
      },
    ));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));

    await tester.tap(find.byKey(const ValueKey('flow-node-goto-answer-impl')));
    await _settle(tester);
    expect(opened, hasLength(1));
    expect(opened.single.agentId, 'agent-live',
        reason: '400ms 重拉之前也应该用事件里的 agent_id 建频道壳');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  test('A6-8: 动作确认提醒排在前面时仍高亮表单卡', () {
    const channelId = 'psess_flow_deadbe12_impl';
    const formId = 'ask-a68-impl';
    // 排序按 createdAt 倒序：动作确认提醒会在表单提醒之前返回。
    PendingApprovalHub.instance.upsert(const PendingApprovalItem(
      id: 'action:confirm-a68',
      channelId: channelId,
      messageId: 'msg-confirm-a68',
      agentId: 'agent-7',
      agentName: 'Agent',
      kind: PendingApprovalKind.action,
      createdAt: 20,
    ));
    PendingApprovalHub.instance.upsert(
      PendingApprovalItem.fromInteraction(
        channelId: channelId,
        agentId: 'agent-7',
        agentName: 'Agent',
        interactionType: 'form',
        data: const {'form_id': formId},
        messageId: 'msg-sid-placeholder',
      )!
          .copyWith(createdAt: 10),
    );
    expect(pendingFlowFormMessageId(channelId),
        PeerApprovalPayload.formCardMessageId(formId));

    // 只有普通提醒时仍退回第一条的消息 id。
    PendingApprovalHub.instance.resetForTest();
    PendingApprovalHub.instance.upsert(const PendingApprovalItem(
      id: 'action:confirm-a68',
      channelId: channelId,
      messageId: 'msg-confirm-a68',
      agentId: 'agent-7',
      agentName: 'Agent',
      kind: PendingApprovalKind.action,
      createdAt: 20,
    ));
    expect(pendingFlowFormMessageId(channelId), 'msg-confirm-a68');

    // DB hydrate 出来的提醒没带 isForm，但消息行是确定性表单卡。
    PendingApprovalHub.instance.upsert(const PendingApprovalItem(
      id: 'action:hydrated-confirm',
      channelId: channelId,
      messageId: 'peer_form_hydrated-form',
      agentId: 'agent-7',
      agentName: 'Agent',
      kind: PendingApprovalKind.action,
      createdAt: 5,
    ));
    expect(pendingFlowFormMessageId(channelId), 'peer_form_hydrated-form');
  });

  testWidgets('P6: 节点弹层里的「去回答」同样打开节点会话', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus)));
    await _settle(tester);

    await tester.tap(find.text('impl'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('node-goto-answer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('node-goto-answer')));
    await _settle(tester);

    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('A4-3: 非真会话 id（group:…）不在运行页外拼 psess 假会话', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      tree: const [
        {
          'key': 'impl',
          'id': 'impl',
          'kind': 'task',
          'status': 'waiting_user',
          'session_id': 'group:g1:s1:flow_x',
          'agent_id': 'agent-7',
        },
      ],
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-node-goto-answer-impl')));
    await _settle(tester);

    expect(opened, isEmpty, reason: '旧引擎槽位 key 拼不出真会话，应留在运行页');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P6: 原有 gate 按钮仍然可用（回归）', (tester) async {
    final picked = <String>[];
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus, onAnswer: picked.add)));
    await _settle(tester);

    expect(find.text('通过'), findsOneWidget);
    await tester.tap(find.text('返工'));
    await _settle(tester);
    expect(picked, ['返工']);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
