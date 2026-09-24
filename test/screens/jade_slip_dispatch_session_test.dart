import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/screens/jade_slip_dispatch.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/composer_draft_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_user_identity.dart';

import '../storage/test_harness.dart';

/// `dispatchJadeSlip` 的会话落点：三种 [JadeSlipSessionTarget] 各把任务发到
/// 哪条 channel。这段 switch 原先没有测试——`ChatService` 是绑死真实
/// `LocalDatabaseService` 的单例，不注册 service locator 就调不到。
///
/// 这里用 [StorageTestHarness] 把 path_provider 顶到临时目录，再跑真实的
/// [setupServiceLocator]，所以断言的是真落库的消息，不是桩的返回值。
///
/// 只断言**用户消息**：它在任何协议发送之前就已落库，因此与 Agent 连不连得上
/// 无关。真正发给 Agent 的那一步是 fire-and-forget，测试里必然失败（没有
/// 可连的 Agent），失败由调用方的 catchError 吞掉。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() {
    setupServiceLocator();
  });

  tearDown(() async {
    await getIt.reset();
  });

  JadeSlip slipFor(String agentId) => JadeSlip(
        id: 'slip-1',
        title: '清单',
        items: const [JadeSlipItem(id: 'a', text: '一件事')],
        // 与下面传的 preferredAgentId 相同，避免触发 JadeSlipService.update
        // 而需要再起一套玉简存储。
        assigneeAgentId: agentId,
        assigneeAgentName: 'Agent $agentId',
        deviceId: 'aaaaaaaaaaaaaaaa',
        createdAt: 0,
        updatedAt: 0,
      );

  /// 落一行 Agent，否则 dispatch 会走「找不到 Agent」的预填兜底分支。
  ///
  /// 协议取 custom 且 endpoint 指向不可达地址：发送必然快速失败，不会在测试
  /// 里挂住等 ACP 连接超时。
  Future<void> seedAgent(WidgetTester tester, String agentId) async {
    await tester.runAsync(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await LocalDatabaseService().createRemoteAgent(RemoteAgent(
        id: agentId,
        name: 'Agent $agentId',
        avatar: '🤖',
        bio: '',
        token: 'tok-$agentId',
        endpoint: 'https://example.invalid',
        protocol: ProtocolType.custom,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        capabilities: const ['chat'],
        metadata: const {},
        createdAt: now,
        updatedAt: now,
      ));
    });
  }

  /// 造一条已有会话，返回它的 channelId。
  Future<String> seedSession(WidgetTester tester, String agentId) async {
    late String id;
    await tester.runAsync(() async {
      id = await ChatService().createNewSession(
        userId: LocalUserIdentity.id,
        userName: LocalUserIdentity.displayName,
        agentId: agentId,
        agentName: 'Agent $agentId',
      );
    });
    return id;
  }

  /// 频道里**用户发的**消息正文。只取 user，避免把 Agent 的回复也算进来
  /// ——custom 协议的假 Agent 会回一条 "Received your message: ..."。
  Future<List<String>> userMessagesIn(
    WidgetTester tester,
    String channelId,
  ) async {
    late List<String> out;
    await tester.runAsync(() async {
      out = (await ChatService().loadChannelMessages(channelId))
          .where((m) => m.from.type == 'user')
          .map((m) => m.content)
          .toList();
    });
    return out;
  }

  Future<void> dispatch(
    WidgetTester tester,
    JadeSlip slip, {
    required JadeSlipSessionTarget target,
    String? channelId,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));

    await tester.runAsync(() async {
      await dispatchJadeSlip(
        ctx,
        slip,
        preferredAgentId: slip.assigneeAgentId,
        sessionTarget: target,
        channelId: channelId,
      );
      // 让 fire-and-forget 的那次发送跑完（必然失败），不要留到下一个用例。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('current 落在该 Agent 最近活跃的会话', (tester) async {
    const agentId = 'agent-current';
    await seedAgent(tester, agentId);
    final existing = await seedSession(tester, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.current);

    // 有会话就不该另起一条：任务落在已有会话上，确定性 id 上什么都不该有。
    expect(await userMessagesIn(tester, existing), [contains('id=slip-1')]);
    expect(
      await userMessagesIn(
        tester,
        ChatService().generateChannelId(LocalUserIdentity.id, agentId),
      ),
      isEmpty,
    );
  });

  testWidgets('current 且没有会话时落到确定性 channelId', (tester) async {
    const agentId = 'agent-no-session';
    await seedAgent(tester, agentId);
    final fallback =
        ChatService().generateChannelId(LocalUserIdentity.id, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.current);

    expect(await userMessagesIn(tester, fallback), hasLength(1));
  });

  testWidgets('fresh 新开一条会话，不复用已有的', (tester) async {
    const agentId = 'agent-fresh';
    await seedAgent(tester, agentId);
    final existing = await seedSession(tester, agentId);
    // 时间戳 id 精确到毫秒，隔开一点免得和下面新建的撞成同一条。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.fresh);

    late List<String> ids;
    await tester.runAsync(() async {
      ids = (await ChatService().getAgentSessions(agentId: agentId))
          .map((c) => c.id)
          .toList();
    });

    final added = ids.where((id) => id != existing).toList();
    expect(added, hasLength(1), reason: 'fresh 应当恰好新增一条会话');
    expect(await userMessagesIn(tester, added.single), hasLength(1));
    expect(await userMessagesIn(tester, existing), isEmpty, reason: '旧会话不该被写入');
  });

  testWidgets('specific 用传进来的 channelId', (tester) async {
    const agentId = 'agent-specific';
    await seedAgent(tester, agentId);
    await seedSession(tester, agentId); // 有会话也不该被选中
    const explicit = 'dm_picked_by_user';

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.specific, channelId: explicit);

    expect(await userMessagesIn(tester, explicit), hasLength(1));
  });

  testWidgets('specific 但没给 channelId 时退到最近活跃会话', (tester) async {
    const agentId = 'agent-specific-fallback';
    await seedAgent(tester, agentId);
    final existing = await seedSession(tester, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.specific);

    expect(await userMessagesIn(tester, existing), hasLength(1));
  });

  /// Agent 行取不到就发不出去，此时退回预填草稿，别把用户确认过的任务丢掉。
  testWidgets('取不到 Agent 行时退回预填草稿', (tester) async {
    const agentId = 'agent-missing';
    final fallback =
        ChatService().generateChannelId(LocalUserIdentity.id, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.current);

    expect(getIt<ComposerDraftService>().getDraft(fallback),
        contains('id=slip-1'));
    expect(await userMessagesIn(tester, fallback), isEmpty, reason: '不该发出消息');
  });
}
