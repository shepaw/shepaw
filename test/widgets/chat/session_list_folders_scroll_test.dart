import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/widgets/chat/agent_session_folders.dart';
import 'package:shepaw/widgets/chat/session_list_panel.dart';

/// 折叠组在会话列表里的位置：跟着列表一起滚，而且不再夹带一个「搜索」行。
///
/// 折叠组最多六行（群聊 / 其他 Agent 发起 / 工作流 / 引擎客户端 / 引擎终端），
/// 早先它钉在滚动区上方，列表再长也不让位，一直占着抽屉顶上一截。这两个用例把
/// 「往上滑时它跟着走」和「列表里没有多余的搜索行」钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatController controller;

  setUp(() {
    FoldedFolderMemory.debugClear();
    controller = ChatController(
      agentId: 'agent-1',
      initialAgentName: 'Agent',
      getUserId: () => 'user-1',
      getUserName: () => 'User',
    );
  });

  tearDown(() => controller.dispose());

  /// 主机只回一个「引擎终端」组，好让折叠组在列表里出现；展开时给出组里的
  /// 一条会话。
  HubFoldedSessions foldersHost(StreamController<PeerControlEvent> bus) =>
      HubFoldedSessions(
        events: bus.stream,
        send: (peerId, frame) async {
          if (frame['folder'] != null) {
            bus.add(PeerControlEvent(peerId: peerId, data: {
              'type': 'agent_sessions_resp',
              'request_id': frame['request_id'],
              'agent_id': 'ra1',
              'folder': frame['folder'],
              'sessions': [
                {
                  'session_id': 'term-1',
                  'title': '在终端里跑测试',
                  'updated_at': 1,
                  'origin': {'kind': 'terminal'},
                },
              ],
            }));
            return true;
          }
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_sessions_resp',
            'request_id': frame['request_id'],
            'agent_id': 'ra1',
            'sessions': [],
            'folders': [
              {'kind': 'ide', 'count': 1, 'latest_title': 'Cursor'},
              {'kind': 'terminal', 'count': 3, 'latest_title': '跑测试'},
            ],
          }));
          return true;
        },
      );

  Widget panel(
    HubFoldedSessions client,
    List<Channel> sessions,
  ) =>
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 360,
              child: SessionListPanel(
                sessions: sessions,
                currentChannelId: 's0',
                controller: controller,
                onNewSession: () {},
                onSwitchSession: (_) {},
                onBatchDelete: (_) {},
                listRefreshTick: ValueNotifier(0),
                selectionModeRequest: ValueNotifier(0),
                foldersClient: client,
                foldersTarget: (peerId: 'p1', remoteAgentId: 'ra1'),
              ),
            ),
          ),
        ),
      );

  /// 折叠组是异步问主机的：等摘要回来再断言。
  Future<void> pumpFolders(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  List<Channel> sessions(int count) => [
        for (var i = 0; i < count; i++)
          Channel(id: 's$i', name: '会话 $i', type: 'dm', members: const []),
      ];

  testWidgets('折叠组跟着列表往上滑，不再钉在顶部', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(panel(foldersHost(bus), sessions(60)));
    await pumpFolders(tester);

    final folder = find.text('引擎终端 · 3');
    expect(folder, findsOneWidget);

    // 起点：折叠组在滚动区里（不是钉在它上方的另一块）。
    final scroll = find.byType(CustomScrollView);
    expect(scroll, findsOneWidget);
    final before = tester.getRect(folder).top;
    expect(before, greaterThanOrEqualTo(tester.getRect(scroll).top - 0.01));

    // 往上滑一点点：折叠组跟着一起走（顶部变小）。滑得多它就整块离开可视区，
    // 那时 getRect 取不到——「钉住」的实现反而会一直取到同一个位置。
    await tester.drag(scroll, const Offset(0, -40));
    await tester.pumpAndSettle();

    final after = tester.getRect(folder).top;
    expect(after, lessThan(before - 1));
    await bus.close();
  });

  testWidgets('展开后滑多远都能点顶上那一行收起', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(panel(foldersHost(bus), sessions(60)));
    await pumpFolders(tester);

    await tester.tap(find.text('引擎终端 · 3'));
    await tester.pumpAndSettle();
    expect(find.text('在终端里跑测试'), findsOneWidget);

    // 滑到私聊区里去：那一行折叠组固定在列表上方，不用滑回去。
    final scroll = find.byType(CustomScrollView);
    await tester.drag(scroll, const Offset(0, -600));
    await tester.pumpAndSettle();
    final listTop = tester.getRect(scroll).top;
    final rowTop = tester.getRect(find.text('引擎终端 · 3')).top;
    expect(rowTop, lessThan(listTop));
    // 会话行照常可见，列表没空白（滚到哪一行取决于行高，这里只断言还有行）。
    expect(find.byType(ListTile), findsWidgets);

    await tester.tap(find.text('引擎终端 · 3'));
    await tester.pumpAndSettle();
    expect(find.text('在终端里跑测试'), findsNothing);
    await bus.close();
  });

  testWidgets('收起后回到展开前的滚动位置', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(panel(foldersHost(bus), sessions(60)));
    await pumpFolders(tester);

    double offset() => tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;

    final scroll = find.byType(CustomScrollView);
    expect(offset(), 0);

    // 展开（此刻在最顶部），然后往下滚一段。
    await tester.tap(find.text('引擎终端 · 3'));
    await tester.pumpAndSettle();
    await tester.drag(scroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(0));

    // 收起：组里的会话行撤掉了，同样的偏移量会落到列表更深的地方，所以要
    // 跳回展开前那个位置。
    await tester.tap(find.text('引擎终端 · 3'));
    await tester.pumpAndSettle();
    expect(offset(), 0);
    await bus.close();
  });

  testWidgets('展开后面的组不会把它挪到前面的组上面', (tester) async {
    // 同一个引擎同时有「引擎客户端」和「引擎终端」：主机顺序是客户端在前、
    // 终端在后。展开终端时它必须留在原位，不能跳到客户端上面。
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(panel(foldersHost(bus), sessions(10)));
    await pumpFolders(tester);

    final ide = find.text('引擎客户端 · 1');
    final terminal = find.text('引擎终端 · 3');
    expect(ide, findsOneWidget);
    expect(terminal, findsOneWidget);
    final ideTop = tester.getRect(ide).top;
    final terminalTop = tester.getRect(terminal).top;
    expect(ideTop, lessThan(terminalTop));

    await tester.tap(terminal);
    await tester.pumpAndSettle();

    // 顺序没变：客户端仍在终端上面。
    expect(tester.getRect(ide).top, ideTop);
    expect(tester.getRect(terminal).top, terminalTop);
    // 终端的会话行铺在它自己那行下面，不是跑到最上面去。
    final item = find.text('在终端里跑测试');
    expect(item, findsOneWidget);
    expect(tester.getRect(item).top, greaterThan(terminalTop));
    await bus.close();
  });

  testWidgets('列表里不再有额外的「搜索会话」行', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(panel(foldersHost(bus), sessions(1)));
    await pumpFolders(tester);

    expect(find.text('引擎终端 · 3'), findsOneWidget);
    // 搜索入口只有抽屉顶部那个搜索框，列表里不再塞一行。
    expect(find.text('搜索会话'), findsNothing);
    expect(find.byIcon(Icons.search), findsNothing);
    await bus.close();
  });
}
