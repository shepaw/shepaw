import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/widgets/chat/group_session_list_panel.dart';
import 'package:shepaw/widgets/chat/session_list_panel.dart';

/// 会话列表固定行高（`ListView.builder` + `prototypeItem`）的前提是**每行渲染
/// 高度一致**：Sliver 拿原型高度当统一 extent，任何一行比原型高都会被压在同一个
/// extent 里，文字叠到下一行上。
///
/// 这些用例锁住前提：列表走原型量高度这条路，且所有行等高、行内文字不越出行框。
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

  Channel dm(
    String id, {
    String? name,
    String? description,
    String? sourceGroupChannelId,
    String? sourceSheChannelId,
  }) {
    return Channel(
      id: id,
      name: name ?? id,
      type: 'dm',
      members: const [],
      description: description,
      sourceGroupChannelId: sourceGroupChannelId,
      sourceSheChannelId: sourceSheChannelId,
    );
  }

  /// 行内所有段落（标题、副标题、角标文字、时间）都必须落在行框内，返回这行
  /// 实际检查到的段落。
  List<RenderParagraph> expectRowContentFits(RenderBox tileBox, String label) {
    final tileRect = tileBox.localToGlobal(Offset.zero) & tileBox.size;
    final paragraphs = <RenderParagraph>[];
    void visit(RenderObject child) {
      if (child is RenderParagraph) {
        paragraphs.add(child);
        final rect = child.localToGlobal(Offset.zero) & child.size;
        expect(
          rect.top >= tileRect.top - 0.01 &&
              rect.bottom <= tileRect.bottom + 0.01,
          isTrue,
          reason: '$label：行内文字越出行框（文字 $rect / 行 $tileRect）',
        );
      }
      child.visitChildren(visit);
    }

    tileBox.visitChildren(visit);
    return paragraphs;
  }

  /// 列表内的会话行（不含列表外的「新建会话」行）。
  Finder rowsInList() => find.descendant(
        of: find.byType(ListView),
        matching: find.byType(ListTile),
      );

  /// 断言列表内所有会话行等高，且每行文字都不越界；返回行高与每行的段落。
  (double, List<List<RenderParagraph>>) expectUniformRows(
    WidgetTester tester,
  ) {
    final heights = <double>{};
    final rows = <List<RenderParagraph>>[];
    for (final element in rowsInList().evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox) continue;
      heights.add(box.size.height);
      rows.add(expectRowContentFits(box, '会话行'));
    }
    expect(rows, isNotEmpty, reason: '列表里没有渲染出任何会话行');
    // 每行至少要有标题 + 副标题两段：段落数为 0 说明越界检查是空跑的。
    for (final row in rows) {
      expect(row.length, greaterThanOrEqualTo(2), reason: '会话行缺少标题/副标题');
    }
    expect(
      heights.length,
      1,
      reason: '会话行高度不一致：$heights（prototypeItem 要求所有行等高）',
    );
    return (heights.single, rows);
  }

  /// 列表本身必须走「原型量高度」这条固定 extent 路径。
  void expectPrototypeExtentList(WidgetTester tester) {
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.prototypeItem, isNotNull);
    expect(list.itemExtent, isNull);
  }

  /// 在桌面宽度下挂载面板：`LayoutUtils.isDesktopLayout` 为真，每行 trailing
  /// 还带「更多」按钮，是行内容最宽 / 最高的一档（手机宽度下 trailing 更小，
  /// 不会更差）。[textScale] 用来覆盖系统字号放大。
  Future<void> pumpPanel(
    WidgetTester tester,
    Widget panel, {
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: SizedBox(width: 320, height: 560, child: panel)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('DM 会话各行等高、文字不越界', (tester) async {
    final sessions = [
      // 无消息、无描述：副标题只有一行兜底文案（最矮的内容形态）。
      dm('s1', name: '短会话'),
      // 绑定会话带长描述：副标题占满两行（最高的内容形态）。
      dm(
        's2',
        name: '群绑定会话',
        description: '这是一段很长的会话描述，用来把副标题撑到两行高度，' * 3,
        sourceGroupChannelId: 'g1',
      ),
      // 标题行带 She 角标。
      dm('s3', name: 'She 绑定会话', sourceSheChannelId: 'she-1'),
      // 当前会话（底色 + 未读归零），且描述同样撑满两行。
      dm('s4', name: '当前会话', description: '当前会话的描述文字补充' * 6),
    ];

    await pumpPanel(
      tester,
      SessionListPanel(
        sessions: sessions,
        currentChannelId: 's4',
        controller: controller,
        onNewSession: () {},
        onSwitchSession: (_) {},
        onBatchDelete: (_) {},
        listRefreshTick: ValueNotifier(0),
        selectionModeRequest: ValueNotifier(0),
      ),
    );

    expectPrototypeExtentList(tester);
    expect(rowsInList(), findsNWidgets(sessions.length));
    final (rowHeight, rows) = expectUniformRows(tester);
    expect(rowHeight, greaterThan(0));

    // 最高的一档内容确实被覆盖到了：长描述的副标题真的排成两行（高度约为
    // 单行兜底副标题的两倍），否则这组用例等于只测了矮行。
    final paragraphs = rows.expand((r) => r).toList();
    final twoLine = paragraphs.firstWhere(
      (p) => p.text.toPlainText().startsWith('这是一段很长的会话描述'),
    );
    final oneLine = paragraphs.firstWhere(
      (p) => p.text.toPlainText() == '暂无消息',
    );
    expect(twoLine.size.height, greaterThan(oneLine.size.height * 1.5));

    // 「新建会话」行已移出列表（它比会话行矮，留在列表里会破坏等高前提），
    // 现在固定在列表上方。
    expect(find.text('新建会话'), findsOneWidget);
    expect(
      tester.getRect(find.text('新建会话')).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(ListView)).top + 0.01),
    );
  });

  testWidgets('群会话各行等高、文字不越界', (tester) async {
    final sessions = [
      Channel(id: 'g1', name: '群会话', type: 'group', members: const []),
      Channel(
        id: 'g2',
        name: '子会话',
        type: 'group',
        members: const [],
        parentGroupId: 'g1',
        description: '子会话描述，长度足以把副标题撑到两行，' * 3,
      ),
      Channel(
        id: 'g3',
        name: '又一个子会话',
        type: 'group',
        members: const [],
        parentGroupId: 'g1',
      ),
    ];

    await pumpPanel(
      tester,
      GroupSessionListPanel(
        sessions: sessions,
        currentChannelId: 'g1',
        controller: controller,
        onNewSession: () {},
        onSwitchSession: (_) {},
        onBatchDelete: (_) {},
        listRefreshTick: ValueNotifier(0),
        selectionModeRequest: ValueNotifier(0),
      ),
    );

    expectPrototypeExtentList(tester);
    expect(rowsInList(), findsNWidgets(sessions.length));
    expectUniformRows(tester);
  });

  testWidgets('批量选择模式下各行等高、文字不越界', (tester) async {
    final sessions = [
      dm('s1', name: '普通会话'),
      dm(
        's2',
        name: '绑定会话',
        description: '绑定会话的描述，长度足以把副标题撑到两行，' * 3,
        sourceGroupChannelId: 'g1',
      ),
    ];
    final selectionRequest = ValueNotifier(0);

    await pumpPanel(
      tester,
      SessionListPanel(
        sessions: sessions,
        currentChannelId: 's1',
        controller: controller,
        onNewSession: () {},
        onSwitchSession: (_) {},
        onBatchDelete: (_) {},
        listRefreshTick: ValueNotifier(0),
        selectionModeRequest: selectionRequest,
      ),
    );

    // 进选择模式：行首多一个复选框（leading 变宽），副标题可能变单行。
    selectionRequest.value++;
    await tester.pump();

    expect(find.byType(Checkbox), findsWidgets);
    expectPrototypeExtentList(tester);
    expectUniformRows(tester);
  });

  testWidgets('抽屉整棵销毁后重开，仍按上次位置恢复滚动', (tester) async {
    final bucket = PageStorageBucket();
    final sessions = [
      for (var i = 0; i < 60; i++) dm('s$i', name: '会话 $i'),
    ];

    Widget build() => MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: Center(
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
                  ),
                ),
              ),
            ),
          ),
        );

    double offset() => tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;

    await tester.pumpWidget(build());
    await tester.pump();
    expect(offset(), 0);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final scrolled = offset();
    expect(scrolled, greaterThan(0));

    // 收起抽屉 = 整棵路由销毁（App 侧是 Navigator.pop），再重新划开。
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    await tester.pumpWidget(build());
    await tester.pump();

    expect(offset(), closeTo(scrolled, 0.5));
  });

  testWidgets('系统字号放大后行高随之变高，仍然等高、不越界', (tester) async {
    final sessions = [
      dm('s1', name: '短会话'),
      dm(
        's2',
        name: '群绑定会话',
        description: '这是一段很长的会话描述，用来把副标题撑到两行高度，' * 3,
        sourceGroupChannelId: 'g1',
      ),
    ];

    await pumpPanel(
      tester,
      SessionListPanel(
        sessions: sessions,
        currentChannelId: 's1',
        controller: controller,
        onNewSession: () {},
        onSwitchSession: (_) {},
        onBatchDelete: (_) {},
        listRefreshTick: ValueNotifier(0),
        selectionModeRequest: ValueNotifier(0),
      ),
      textScale: 2.0,
    );

    final (rowHeight, _) = expectUniformRows(tester);
    // 原型是照着会话行结构搭的（不是写死的 72），字号翻倍时 extent 跟着长，
    // 所以内容不会被压回固定像素里。
    expect(rowHeight, greaterThan(72));
  });
}
