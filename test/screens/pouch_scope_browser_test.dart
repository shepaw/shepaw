import 'dart:typed_data';

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

Widget _screen(PouchScopeStore store, {PouchScope? initialScope}) => MaterialApp(
      // 页面文案走 l10n，测试树必须自己装上委托，否则 AppLocalizations.of
      // 拿不到值（见 pouch_scope_browser_screen 的提示词与按钮文案）。
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PouchScopeBrowserScreen(
        store: store,
        initialScope: initialScope,
      ),
    );

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
    await tester.tap(find.byTooltip('删除'));
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

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(transport.deletes, [
      (scope: 'agent:a1', path: 'notes/a.md'),
    ]);
  });
}