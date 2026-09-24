import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/screens/jade_slip_editor_screen.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/local_store.dart';

import '../storage/test_harness.dart';

/// 玉简「交给 Agent」入口的回归：
/// - 顶栏按钮：只把**待办项**交给 Agent，不是整份清单
/// - 清单项右侧菜单：可以只派发**这一项**
/// - 两个入口都先弹确认弹层，弹层里能改 Agent、选会话
///
/// LocalStore 走真实文件 IO，因此整段交互包在 [WidgetTester.runAsync] 里。
void main() {
  late Directory tmp;
  late LocalStore store;
  const self = 'aaaaaaaaaaaaaaaa';

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jade_slip_handoff_test');
    store = LocalStore(root: tmp)..debugSkipVolumeQuota = true;
    JadeSlipService.instance.debugStore = store;
    JadeSlipService.instance.debugDeviceId = self;
  });

  tearDown(() async {
    JadeSlipService.instance.debugStore = null;
    JadeSlipService.instance.debugDeviceId = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  /// 跨过弹层/菜单的路由动画：动画没走完时弹层挡着指针，点不中里面的项。
  Future<void> pumpAnim(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  Future<String> pumpEditor(WidgetTester tester, String slipId) async {
    await tester.pumpWidget(app(Scaffold(
      body: JadeSlipEditorScreen(slipId: slipId, embedded: true),
    )));
    await settle(tester);
    await settle(tester);
    return slipId;
  }

  /// 一条两项、其中一项已完成的玉简：用来区分「待办」与「全部」。
  Future<String> seedSlip() async {
    final slip = await JadeSlipService.instance.create(
      title: '清单',
      items: const [
        JadeSlipItem(id: 'done1', text: '已经做完的'),
        JadeSlipItem(id: 'open1', text: '还没做的'),
      ],
    );
    await JadeSlipService.instance
        .setItemDone(id: slip.id, itemId: 'done1', done: true);
    return slip.id;
  }

  testWidgets('顶栏「交给 Agent」范围是待办项，且先弹确认', (tester) async {
    await tester.runAsync(() async {
      await pumpEditor(tester, await seedSlip());

      await tester.tap(find.text('交给 Agent'));
      await settle(tester);
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      // 2 项里 1 项已完成 → 只交待办的那 1 项。
      expect(find.text('待办 1 项（共 2 项）'), findsOneWidget);

      // 弹层给出三种会话选择与「修改」入口。
      expect(find.text('当前会话'), findsOneWidget);
      expect(find.text('新开会话'), findsOneWidget);
      expect(find.text('指定会话'), findsOneWidget);
      expect(find.text('修改'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets('清单项右侧菜单可只派发这一项', (tester) async {
    await tester.runAsync(() async {
      await pumpEditor(tester, await seedSlip());

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await pumpAnim(tester);

      // 顶栏按钮也叫「交给 Agent」，这里要的是清单项弹层里的那一条。
      final menuItem = find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.text('交给 Agent'),
      );
      expect(menuItem, findsOneWidget);

      await tester.tap(menuItem);
      await settle(tester);
      await pumpAnim(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      // 单项入口：范围就是被点的那一项，不是待办集合。
      expect(find.text('清单项「已经做完的」'), findsOneWidget);
      expect(find.text('待办 1 项（共 2 项）'), findsNothing);
    });
  });

  testWidgets('清单全部完成时顶栏按钮不再派发', (tester) async {
    await tester.runAsync(() async {
      final slip = await JadeSlipService.instance.create(
        title: '清单',
        items: const [JadeSlipItem(id: 'only', text: '就这一项')],
      );
      await JadeSlipService.instance
          .setItemDone(id: slip.id, itemId: 'only', done: true);
      await pumpEditor(tester, slip.id);

      await tester.tap(find.text('交给 Agent'));
      await settle(tester, 500);

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text('清单已全部完成，没有待办项可以交给 Agent'),
        findsOneWidget,
      );
    });
  });
}
