import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/screens/jade_slip_dispatch.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/composer_draft_service.dart';
import 'package:shepaw/services/local_user_identity.dart';

import '../storage/test_harness.dart';

/// `dispatchJadeSlip` 的会话落点：三种 [JadeSlipSessionTarget] 各把草稿写到
/// 哪条 channel。这段 switch 原先没有测试——`ChatService` 是绑死真实
/// `LocalDatabaseService` 的单例，不注册 service locator 就调不到。
///
/// 这里用 [StorageTestHarness] 把 path_provider 顶到临时目录，跑的是**真实**
/// ChatService + 真实 ffi 数据库，所以断言的是真的会话落点，不是桩的返回值。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  late ComposerDraftService drafts;

  setUp(() {
    drafts = ComposerDraftService();
    getIt.registerSingleton<ComposerDraftService>(drafts);
    getIt.registerSingleton<ChatService>(ChatService());
  });

  tearDown(() async {
    // 放掉 setDraft 的 400ms 落盘去抖，别把定时器留到下一个用例。
    await drafts.flush();
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
      await drafts.flush();
    });
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('current 落在该 Agent 最近活跃的会话', (tester) async {
    const agentId = 'agent-current';
    final existing = await seedSession(tester, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.current);

    // 有会话就不该另起一条：草稿落在已有会话上，确定性 id 上什么都不该有。
    expect(drafts.getDraft(existing), contains('id=slip-1'));
    expect(
      drafts.getDraft(ChatService().generateChannelId(
        LocalUserIdentity.id,
        agentId,
      )),
      isEmpty,
    );
  });

  testWidgets('current 且没有会话时落到确定性 channelId', (tester) async {
    const agentId = 'agent-no-session';
    final fallback =
        ChatService().generateChannelId(LocalUserIdentity.id, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.current);

    expect(drafts.getDraft(fallback), contains('id=slip-1'));
  });

  testWidgets('fresh 新开一条会话，不复用已有的', (tester) async {
    const agentId = 'agent-fresh';
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
    expect(drafts.getDraft(added.single), contains('id=slip-1'));
    expect(drafts.getDraft(existing), isEmpty, reason: '旧会话不该被写入');
  });

  testWidgets('specific 用传进来的 channelId', (tester) async {
    const agentId = 'agent-specific';
    await seedSession(tester, agentId); // 有会话也不该被选中
    const explicit = 'dm_picked_by_user';

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.specific, channelId: explicit);

    expect(drafts.getDraft(explicit), contains('id=slip-1'));
  });

  testWidgets('specific 但没给 channelId 时退到最近活跃会话', (tester) async {
    const agentId = 'agent-specific-fallback';
    final existing = await seedSession(tester, agentId);

    await dispatch(tester, slipFor(agentId),
        target: JadeSlipSessionTarget.specific);

    expect(drafts.getDraft(existing), contains('id=slip-1'));
  });
}
