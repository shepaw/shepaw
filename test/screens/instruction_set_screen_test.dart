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

/// 真实 UI 链路：真实 [InstructionSetScreen] + 真实（ffi）数据库。
/// 宽窗口走主从：空列表里的系统指令 → 右侧新建并自动保存 → 删除。
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

  testWidgets('full journey: system seeded → create → detail → delete', (tester) async {
    await pumpScreen(tester);
    expect(find.text('指令集'), findsOneWidget);
    expect(find.text('沉淀指令'), findsOneWidget);

    await tester.tap(find.byTooltip('新建指令'));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.enterText(find.byKey(const ValueKey('instruction-name')), '周报');
      await tester.enterText(
          find.byKey(const ValueKey('instruction-desc')), '每周一自动输出');
      await tester.enterText(
          find.byKey(const ValueKey('instruction-content')), '总结上周进度与本周计划');
      // 停笔后自动保存，并等真实数据库写完。
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(find.text('周报'), findsWidgets);
    final items = (await tester.runAsync(
            () => InstructionSetService.instance.list())) ??
        const [];
    final mine = items
        .where((e) => e.name != InstructionSetService.systemInstructionName)
        .toList();
    expect(mine.length, 1);
    expect(mine.first.name, '周报');
    expect(mine.first.ownerAgentId, SheService.sheId);

    expect(find.text('执行'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.textContaining('总结上周进度与本周计划'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('确定删除'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.text('周报'), findsNothing);
    final after =
        await tester.runAsync(() => InstructionSetService.instance.list()) ??
            const [];
    expect(
      after.where((e) => e.name != InstructionSetService.systemInstructionName),
      isEmpty,
    );
  });
}
