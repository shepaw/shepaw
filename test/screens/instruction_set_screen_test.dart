import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/screens/instruction_set_screen.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/instruction_set_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

/// 真实 UI 链路：真实 [InstructionSetScreen] + 真实（ffi）数据库，一次用例
/// 走完整条主路径：空态 → 新建对话框落库 → 列表展示 → 详情面板 → 删除。
///
/// DB 走真实异步，testWidgets 的 FakeAsync 下无法完成，因此所有涉及 DB
/// 的操作（含测试里的验证读取）都必须包在 runAsync 里，否则 `await` 真实
/// future 会死锁。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await StorageTestHarness.init();
    setupServiceLocator();
  });

  setUp(() async {
    final db = LocalDatabaseService();
    final handle = await db.database;
    await handle.delete('instruction_sets');
    await handle.delete('agents');
    // 模拟真实环境：agents 表里已有 She 自身。新建对话框的下拉必须排除
    // She（已有硬编码项），否则 DropdownButton 出现重复 value 断言崩溃。
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.createRemoteAgent(RemoteAgent(
      id: SheService.sheId,
      name: '惜宝',
      token: 't',
      endpoint: 'local',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: now,
      updatedAt: now,
    ));
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: InstructionSetScreen(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('full journey: empty → create → detail → delete', (tester) async {
    // ── 空态 ──
    await pumpScreen(tester);
    expect(find.text('指令集'), findsOneWidget);
    expect(find.textContaining('暂无指令'), findsOneWidget);

    // ── 新建（真实 DB 落库） ──
    await tester.runAsync(() async {
      await tester.tap(find.text('新建指令'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField).at(0), '周报');
      await tester.enterText(find.byType(TextField).at(1), '每周一自动输出');
      await tester.enterText(find.byType(TextField).at(2), '总结上周进度与本周计划');
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 300));
      // 让对话框关闭后的列表 reload 在真实异步里完成。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
    });

    expect(find.text('周报'), findsWidgets);
    final items = (await tester.runAsync(
            () => InstructionSetService.instance.list())) ??
        const [];
    expect(items.length, 1);
    expect(items.first.name, '周报');
    expect(items.first.ownerAgentId, SheService.sheId);

    // ── 详情面板（执行 / 编辑 / 删除入口） ──
    await tester.tap(find.text('周报').first);
    await tester.pumpAndSettle();
    expect(find.text('执行'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.textContaining('总结上周进度与本周计划'), findsOneWidget);

    // ── 删除（确认对话框 + 真实 DB 删除） ──
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('确定删除'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.text('周报'), findsNothing);
    expect(
      await tester.runAsync(() => InstructionSetService.instance.list()),
      isEmpty,
    );
  });
}
