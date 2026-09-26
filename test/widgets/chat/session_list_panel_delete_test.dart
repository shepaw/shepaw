import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/widgets/chat/group_session_list_panel.dart';
import 'package:shepaw/widgets/chat/session_list_panel.dart';

/// 会话行「删除」入口（长按菜单 / 桌面「更多」下拉）的面板侧行为：
/// 确认后按单会话走批量删除同一条路径，取消则什么都不做。
///
/// 菜单本身只负责派发动作（见 session_row_menu_test.dart），确认弹窗在
/// 面板里弹。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatController controller;

  setUp(() {
    controller = ChatController(
      agentId: 'agent-1',
      initialAgentName: 'Agent',
      getUserId: () => 'user-1',
      getUserName: () => 'User',
    );
  });

  tearDown(() => controller.dispose());

  Channel dm(String id) =>
      Channel(id: id, name: id, type: 'dm', members: const []);

  /// 手机宽度挂载面板：桌面上长按被禁用（改用「更多」菜单），这里要测长按。
  /// 面板挂在一个独立路由上，删除后 `closePanelRoute` 的 pop 才有落点。
  Future<void> pumpPanel(WidgetTester tester, Widget panel) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => Scaffold(body: panel)),
                ),
                child: const Text('open panel'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open panel'));
    await tester.pumpAndSettle();
  }

  Widget dmPanel({
    required List<Channel> sessions,
    String? currentChannelId,
    required ValueChanged<List<String>> onBatchDelete,
  }) {
    return SessionListPanel(
      sessions: sessions,
      currentChannelId: currentChannelId,
      controller: controller,
      onNewSession: () {},
      onSwitchSession: (_) {},
      onBatchDelete: onBatchDelete,
      listRefreshTick: ValueNotifier(0),
      selectionModeRequest: ValueNotifier(0),
    );
  }

  testWidgets('长按非当前会话：确认后按该会话 id 删除并关掉面板', (tester) async {
    List<String>? deletedIds;
    await pumpPanel(
      tester,
      dmPanel(
        sessions: [dm('s1'), dm('s2')],
        currentChannelId: 's2',
        onBatchDelete: (ids) => deletedIds = ids,
      ),
    );

    await tester.longPress(find.text('s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();

    // 确认弹窗（标题同样是「删除会话」，正文说明不可撤销）。
    expect(find.text('这将删除此会话及其所有消息，此操作不可撤销。'), findsOneWidget);
    expect(deletedIds, isNull);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(deletedIds, ['s1']);
    expect(find.text('s1'), findsNothing, reason: '删完应关掉面板');
  });

  testWidgets('确认框点取消不删除', (tester) async {
    List<String>? deletedIds;
    await pumpPanel(
      tester,
      dmPanel(
        sessions: [dm('s1'), dm('s2')],
        currentChannelId: 's2',
        onBatchDelete: (ids) => deletedIds = ids,
      ),
    );

    await tester.longPress(find.text('s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(deletedIds, isNull);
    expect(find.text('s1'), findsOneWidget);
  });

  testWidgets('正在查看的会话长按菜单里没有删除', (tester) async {
    await pumpPanel(
      tester,
      dmPanel(
        sessions: [dm('s1'), dm('s2')],
        currentChannelId: 's2',
        onBatchDelete: (_) => fail('当前会话不该触发删除'),
      ),
    );

    await tester.longPress(find.text('s2'));
    await tester.pumpAndSettle();
    expect(find.text('复制会话信息'), findsOneWidget, reason: '菜单确实弹出来了');
    expect(find.text('删除会话'), findsNothing);
  });

  testWidgets('群根会话没有删除，群子会话有', (tester) async {
    final sessions = [
      Channel(id: 'g1', name: 'group root', type: 'group', members: const []),
      Channel(
        id: 'g2',
        name: 'child',
        type: 'group',
        members: const [],
        parentGroupId: 'g1',
      ),
    ];
    await pumpPanel(
      tester,
      GroupSessionListPanel(
        sessions: sessions,
        // 不设当前会话：两个判断（当前会话 / 群根会话）分开验证。
        controller: controller,
        onNewSession: () {},
        onSwitchSession: (_) {},
        onBatchDelete: (_) {},
        listRefreshTick: ValueNotifier(0),
        selectionModeRequest: ValueNotifier(0),
      ),
    );

    await tester.longPress(find.text('child'));
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsOneWidget);
    // 取消掉确认框，面板留着继续验群根会话那一行。
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('group root'));
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsNothing, reason: '群根会话只能解散，不能这样删');
  });
}
