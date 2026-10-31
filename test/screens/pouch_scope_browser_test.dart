import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/screens/pouch_scope_browser_screen.dart';
import 'package:shepaw/storage/group_shared_files.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

class _Transport implements PouchScopeTransport {
  _Transport({this.scopeIds = const <String>[], this.entries, this.error});

  final List<String> scopeIds;
  final List<StoreEntry>? entries;
  final StoreException? error;
  final deletes = <({String scope, String path})>[];

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return scopeIds;
  }

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async => null;

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return PouchListPage(entries: entries ?? const <StoreEntry>[]);
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async => null;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {}

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    deletes.add((scope: scope.id, path: path));
  }
}

Widget _screen(
  PouchScopeStore store, {
  PouchScope? initialScope,
  bool lockToInitialScope = false,
}) =>
    MaterialApp(
      // 页面文案走 l10n，测试树必须自己装上委托，否则 AppLocalizations.of
      // 拿不到值（见 pouch_scope_browser_screen 的提示词与按钮文案）。
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        initialScope: initialScope,
        lockToInitialScope: lockToInitialScope,
      ),
    );

/// 文件页的一条假数据：docs 下两层 + 根目录一个文件 + 一个内部占位文件。
List<StoreEntry> _fileEntries() => <StoreEntry>[
      StoreEntry(path: 'docs/report.pdf', size: 1200, sha256: '', mtimeMs: 3000),
      StoreEntry(path: 'note.md', size: 10, sha256: '', mtimeMs: 1000),
      StoreEntry(path: 'docs/sub/old.md', size: 5, sha256: '', mtimeMs: 500),
      StoreEntry(path: '.keep', size: 0, sha256: '', mtimeMs: 9000),
    ];

void _setViewport(WidgetTester tester, {required double w, required double h}) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('顶层列 scope：只留能直接看文件的那些，会话不占位', (tester) async {
    // 顶层是一整页 ListView：把视口拉高，最后几组（技能/玉简）才会被 build。
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = PouchScopeStore(
      transport: _Transport(
        scopeIds: <String>[
          'agent:agent_a',
          'group:group_a',
          'group:group_a:shared',
          'group:group_a:session:s_1',
          'skill:writer',
          'slip:sl_1',
        ],
      ),
      pouchId: 'p1',
    );
    await tester.pumpWidget(_screen(store));
    await tester.pumpAndSettle();

    expect(find.text('玉简 sl_1'), findsOneWidget);
    expect(find.text('助手 agent_a'), findsOneWidget);
    expect(find.text('群 group_a'), findsOneWidget);
    expect(find.text('群 group_a · 共享'), findsOneWidget);
    expect(find.text('技能 writer'), findsOneWidget);
    // 会话不占顶层。
    expect(find.text('会话 s_1'), findsNothing);
  });

  testWidgets('空 scope 说「还没有文件」，不是报错', (tester) async {
    final store = PouchScopeStore(
      transport: _Transport(entries: const <StoreEntry>[]),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.groupShared('group_a')),
    );
    await tester.pumpAndSettle();

    expect(find.text('这个位置还没有文件'), findsOneWidget);
    expect(find.textContaining('acl_denied'), findsNothing);
  });

  testWidgets('读不到时给错误码，不显示成空列表', (tester) async {
    final store = PouchScopeStore(
      transport: _Transport(
        error: StoreException(StoreError.aclDenied, 'acl_denied'),
      ),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.groupShared('group_a')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('acl_denied'), findsOneWidget);
    expect(find.text('这个位置还没有文件'), findsNothing);
  });

  testWidgets('scope 名单读不到时给错误码，固定四个分区照常显示', (tester) async {
    final store = PouchScopeStore(
      transport: _Transport(
        error: StoreException(StoreError.notPaired, 'not_paired'),
      ),
      pouchId: 'p1',
    );
    await tester.pumpWidget(_screen(store));
    await tester.pumpAndSettle();

    expect(find.textContaining('not_paired'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });

  testWidgets('给了旧数据入口就显示 space 页的入口', (tester) async {
    final store = PouchScopeStore(
      transport: _Transport(),
      pouchId: 'p1',
    );
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        onOpenLegacy: () => opened++,
      ),
    ));
    await tester.pumpAndSettle();
    final legacy = find.text('旧数据（space 目录）');
    expect(legacy, findsOneWidget);
    await tester.tap(legacy);
    expect(opened, 1);
  });

  test('上传落点：子目录保持不动，scope 根按布局选约定目录', () {
    expect(
      PouchScopeBrowserScreen.uploadDirFor(PouchScope.slip('sl1'), ''),
      'files',
    );
    expect(
      PouchScopeBrowserScreen.uploadDirFor(
        PouchScope.agentSession('a1', 's1'),
        '',
      ),
      'attachments',
    );
    expect(
      PouchScopeBrowserScreen.uploadDirFor(PouchScope.agent('a1'), ''),
      'files/attachments',
    );
    expect(
      PouchScopeBrowserScreen.uploadDirFor(PouchScope.groupShared('g1'), '/'),
      '',
      reason: '群共享的 files/ 前缀由 GroupSharedFiles 加',
    );
    expect(
      PouchScopeBrowserScreen.uploadDirFor(PouchScope.slip('sl1'), 'files/docs'),
      'files/docs',
    );
  });

  testWidgets('群共享删文件走 GroupSharedFiles：带 files/ 前缀', (tester) async {
    final transport = _Transport(entries: <StoreEntry>[
      StoreEntry(path: 'files/a.md', size: 3, sha256: '', mtimeMs: 0),
    ]);
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        initialScope: PouchScope.groupShared('g1'),
        initialPath: GroupSharedFiles.filesDir,
        sharedFiles: GroupSharedFiles(scopes: store),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('a.md'), findsOneWidget);
    // 删除不在行尾了：长按出操作菜单，删除在菜单里。
    await tester.longPress(find.widgetWithText(ListTile, 'a.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(transport.deletes, [
      (scope: 'group:g1:shared', path: 'files/a.md'),
    ]);
  });

  testWidgets('普通 scope 删文件：按当前目录的相对路径删', (tester) async {
    final transport = _Transport(entries: <StoreEntry>[
      StoreEntry(path: 'notes/a.md', size: 3, sha256: '', mtimeMs: 0),
    ]);
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        initialScope: PouchScope.agent('a1'),
        initialPath: 'notes',
      ),
    ));
    await tester.pumpAndSettle();

    // 桌面右键也出同一个菜单。
    await tester.tap(
      find.widgetWithText(ListTile, 'a.md'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(transport.deletes, [
      (scope: 'agent:a1', path: 'notes/a.md'),
    ]);
  });

  testWidgets('长按出操作菜单，删除要确认，取消就不删', (tester) async {
    final transport = _Transport(entries: <StoreEntry>[
      StoreEntry(path: 'notes/a.md', size: 3, sha256: '', mtimeMs: 0),
    ]);
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        initialScope: PouchScope.agent('a1'),
        initialPath: 'notes',
      ),
    ));
    await tester.pumpAndSettle();

    // 行尾不再挂删除按钮。
    expect(find.byTooltip('删除'), findsNothing);

    await tester.longPress(find.widgetWithText(ListTile, 'a.md'));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 确认框：取消就什么都不删。
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(transport.deletes, isEmpty);

    await tester.longPress(find.widgetWithText(ListTile, 'a.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(transport.deletes, [
      (scope: 'agent:a1', path: 'notes/a.md'),
    ]);
  });

  testWidgets('批量操作：勾上复选框，一次删掉选中的几项', (tester) async {
    _setViewport(tester, w: 1400, h: 1000);
    final transport = _Transport(entries: <StoreEntry>[
      StoreEntry(path: 'a.md', size: 1, sha256: '', mtimeMs: 100),
      StoreEntry(path: 'b.md', size: 1, sha256: '', mtimeMs: 200),
      StoreEntry(path: 'docs', size: 0, sha256: '', mtimeMs: 300, kind: 'dir'),
    ]);
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    // 平时没有复选框。
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();

    // 批量操作按钮换成取消 / 删除，标题变成已选条数。
    expect(find.byTooltip('批量操作'), findsNothing);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('已选 0 项'), findsOneWidget);
    // 目录不给勾（删不掉），只有两个文件有复选框。
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.widgetWithText(ListTile, 'a.md'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    // 批量模式下点行只勾不选，不会打开文件。
    await tester.tap(find.widgetWithText(ListTile, 'b.md'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('删除 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(transport.deletes, [
      (scope: 'files', path: 'a.md'),
      (scope: 'files', path: 'b.md'),
    ]);
    // 删完退出批量模式。
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byTooltip('批量操作'), findsOneWidget);
  });

  testWidgets('批量操作可以取消，复选框收起来', (tester) async {
    _setViewport(tester, w: 1400, h: 1000);
    final transport = _Transport(entries: <StoreEntry>[
      StoreEntry(path: 'a.md', size: 1, sha256: '', mtimeMs: 100),
      StoreEntry(path: 'b.md', size: 1, sha256: '', mtimeMs: 200),
    ]);
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'a.md'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byTooltip('批量操作'), findsOneWidget);
    expect(transport.deletes, isEmpty);
    // 退出后点行又是打开文件，不是勾选。
    expect(find.text('已选 0 项'), findsNothing);
  });

  test('recentScopeFiles：新→旧，丢掉目录和点开头的文件，按 limit 截断', () {
    final entries = <StoreEntry>[
      StoreEntry(path: 'a.md', size: 1, sha256: '', mtimeMs: 100),
      StoreEntry(path: '.keep', size: 0, sha256: '', mtimeMs: 900),
      StoreEntry(path: 'docs', size: 0, sha256: '', mtimeMs: 800, kind: 'dir'),
      StoreEntry(path: 'b.md', size: 1, sha256: '', mtimeMs: 300),
      StoreEntry(path: 'c.md', size: 1, sha256: '', mtimeMs: 200),
    ];
    expect(
      recentScopeFiles(entries).map((e) => e.path).toList(),
      ['b.md', 'c.md', 'a.md'],
    );
    expect(
      recentScopeFiles(entries, limit: 2).map((e) => e.path).toList(),
      ['b.md', 'c.md'],
    );
  });

  testWidgets('文件页左栏是「最近 / 全部文件 / 文件夹」，不再只列一个 files',
      (tester) async {
    _setViewport(tester, w: 1400, h: 1000);
    final store = PouchScopeStore(
      transport: _Transport(entries: _fileEntries()),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近'), findsOneWidget);
    expect(find.text('全部文件'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    // 根目录下的文件夹当快捷入口列在左栏；内容区也有一份。
    expect(find.widgetWithText(ListTile, 'docs'), findsNWidgets(2));
  });

  testWidgets('进到子目录后，点路径栏的「文件」回到根目录', (tester) async {
    _setViewport(tester, w: 1400, h: 1000);
    final store = PouchScopeStore(
      transport: _Transport(entries: _fileEntries()),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    // 内容区那个 docs（左栏还有一个同名快捷入口，排在前面）。
    await tester.tap(find.widgetWithText(ListTile, 'docs').last);
    await tester.pumpAndSettle();
    expect(find.text('文件 / docs'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'report.pdf'), findsOneWidget);

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('文件 / docs'), findsNothing);
    expect(find.widgetWithText(ListTile, 'note.md'), findsOneWidget);
  });

  testWidgets('子目录里系统返回先上一级，到根目录才关页', (tester) async {
    _setViewport(tester, w: 1400, h: 1000);
    final store = PouchScopeStore(
      transport: _Transport(entries: _fileEntries()),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    PopScope<Object?> popScope() =>
        tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>));
    // 根目录：返回键直接关掉整页。
    expect(popScope().canPop, isTrue);

    await tester.tap(find.widgetWithText(ListTile, 'docs').last);
    await tester.pumpAndSettle();
    expect(popScope().canPop, isFalse);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    // PopScope 吃掉这次返回：didPop=false 的那一路，页面留着、往上走一级。
    final popped = await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(popped, isTrue, reason: '返回被 PopScope 拦下，不再往路由外面冒');
    expect(find.text('文件 / docs'), findsNothing, reason: '应该往上走了一级');
    expect(find.text('全部文件'), findsOneWidget, reason: '整页还在，没被关掉');
    expect(popScope().canPop, isTrue);
  });

  testWidgets('窄屏根目录顶部有「最近」，查看全部进最近视图', (tester) async {
    _setViewport(tester, w: 500, h: 1000);
    final store = PouchScopeStore(
      transport: _Transport(entries: _fileEntries()),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'report.pdf'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'old.md'), findsOneWidget);

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();

    expect(find.text('最近文件'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'note.md'), findsOneWidget);
    // 内部占位文件不进最近。
    expect(find.widgetWithText(ListTile, '.keep'), findsNothing);
    // 路径栏回到「全部文件」的入口还在。
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'docs'), findsOneWidget);
  });

  testWidgets('最近里只剩内部文件时说「最近还没有文件」', (tester) async {
    _setViewport(tester, w: 500, h: 1000);
    final store = PouchScopeStore(
      transport: _Transport(entries: <StoreEntry>[
        StoreEntry(path: '.keep', size: 0, sha256: '', mtimeMs: 9000),
      ]),
      pouchId: 'p1',
    );
    await tester.pumpWidget(
      _screen(store, initialScope: PouchScope.files, lockToInitialScope: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近还没有文件'), findsOneWidget);
    // 内部文件只是不进最近，目录里照旧列出来。
    expect(find.widgetWithText(ListTile, '.keep'), findsOneWidget);
  });
}