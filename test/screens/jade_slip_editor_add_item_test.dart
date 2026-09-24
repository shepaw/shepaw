import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/screens/jade_slip_editor_screen.dart';
import 'package:shepaw/screens/jade_slip_screen.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/local_store.dart';

import '../storage/test_harness.dart';

/// 真实玉简 UI + 真实 LocalStore（临时目录）的焦点回归。
///
/// 清单要能连续录入：回车保存上一条后，光标必须留在「添加一项」输入框。
///
/// LocalStore 走真实文件 IO，`testWidgets` 默认的 FakeAsync 等不到它，
/// 因此整段交互都包在 [WidgetTester.runAsync] 里。
void main() {
  late Directory tmp;
  late LocalStore store;
  const self = 'aaaaaaaaaaaaaaaa';

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jade_slip_editor_test');
    store = LocalStore(root: tmp)..debugSkipVolumeQuota = true;
    JadeSlipService.instance.debugStore = store;
    JadeSlipService.instance.debugDeviceId = self;
  });

  tearDown(() async {
    JadeSlipService.instance.debugStore = null;
    JadeSlipService.instance.debugDeviceId = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 「添加一项」行的输入框（同一页还有评论输入框，用稳定的 key 区分）。
  Finder addItemField() => find.byKey(jadeSlipAddItemFieldKey);

  Finder inlineField(String text) => find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == text,
      );

  bool hasFocus(WidgetTester tester, Finder field) =>
      tester.widget<TextField>(field).focusNode?.hasFocus ?? false;

  /// 物理键盘回车。多行输入框把回车让给了换行，提交改由 [Focus.onKeyEvent]
  /// 在父节点拦截，所以这里必须发真实按键事件，不能再走 done action。
  Future<void> pressEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  /// Shift+Enter：留给 EditableText 换行。
  Future<void> pressShiftEnter(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  /// 让真实 IO 跑完，再渲染一帧。
  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  testWidgets('回车添加清单项后焦点留在「添加一项」，可连续录入', (tester) async {
    await tester.runAsync(() async {
      final slipId = (await JadeSlipService.instance.create(title: '清单')).id;
      await tester.pumpWidget(
        app(Scaffold(
          body: JadeSlipEditorScreen(slipId: slipId, embedded: true),
        )),
      );
      await settle(tester);

      expect(addItemField(), findsOneWidget);

      for (final text in ['第一项', '第二项', '第三项']) {
        await tester.enterText(addItemField(), text);
        await tester.pump();
        await pressEnter(tester);
        await settle(tester, 500);
        await settle(tester);

        expect(hasFocus(tester, addItemField()), isTrue,
            reason: '回车保存「$text」后应保持焦点，便于连续添加');
      }

      final slip = await JadeSlipService.instance.getById(slipId);
      expect(slip?.items.map((i) => i.text), ['第一项', '第二项', '第三项']);
    });
  });

  testWidgets('Shift+Enter 换行不提交；右侧按钮是非键盘提交入口', (tester) async {
    await tester.runAsync(() async {
      final slipId = (await JadeSlipService.instance.create(title: '清单')).id;
      await tester.pumpWidget(
        app(Scaffold(
          body: JadeSlipEditorScreen(slipId: slipId, embedded: true),
        )),
      );
      await settle(tester);

      await tester.enterText(addItemField(), '第一行');
      await tester.pump();
      await pressShiftEnter(tester);
      await tester.pump();

      var slip = await JadeSlipService.instance.getById(slipId);
      expect(slip?.items, isEmpty, reason: 'Shift+Enter 只换行，不应提交');

      // 无修饰键回车仍然提交（肌肉记忆不打破）。
      await pressEnter(tester);
      await settle(tester, 500);
      await settle(tester);
      slip = await JadeSlipService.instance.getById(slipId);
      expect(slip?.items.map((i) => i.text), ['第一行']);

      // 移动端软键盘没有 Shift+Enter，提交要有按钮入口。
      await tester.enterText(addItemField(), '第二行');
      await tester.pump();
      await tester.tap(find.byTooltip('添加清单项'));
      await settle(tester, 500);
      await settle(tester);
      slip = await JadeSlipService.instance.getById(slipId);
      expect(slip?.items.map((i) => i.text), ['第一行', '第二行']);
    });
  });

  testWidgets('行内改完清单项回车，焦点转到「添加一项」', (tester) async {
    await tester.runAsync(() async {
      final slipId = (await JadeSlipService.instance.create(
        title: '清单',
        items: const [JadeSlipItem(id: 'a1', text: '第一项')],
      ))
          .id;
      await tester.pumpWidget(
        app(Scaffold(
          body: JadeSlipEditorScreen(slipId: slipId, embedded: true),
        )),
      );
      await settle(tester);

      await tester.tap(find.text('第一项'));
      await tester.pump();
      expect(inlineField('第一项'), findsOneWidget);

      await tester.enterText(inlineField('第一项'), '第一项改');
      await tester.pump();
      await pressEnter(tester);
      await settle(tester, 500);
      await settle(tester);

      expect(hasFocus(tester, addItemField()), isTrue,
          reason: '行内改完回车后应把焦点交给「添加一项」');

      final slip = await JadeSlipService.instance.getById(slipId);
      expect(slip?.items.map((i) => i.text), ['第一项改']);
    });
  });

  testWidgets('桌面分栏（真实 JadeSlipScreen）里连续添加清单', (tester) async {
    tester.view.physicalSize = const Size(1200 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await JadeSlipService.instance.create(title: '清单');
      await tester.pumpWidget(app(const JadeSlipScreen(embedded: true)));
      await settle(tester);

      // 左侧列表里打开玉简（桌面分栏 → 右侧内嵌编辑器）。
      await tester.tap(find.text('清单').first);
      await settle(tester);
      await settle(tester);
      expect(addItemField(), findsOneWidget);

      await tester.enterText(addItemField(), '第一项');
      await tester.pump();
      await pressEnter(tester);
      await settle(tester, 500);
      await settle(tester);

      expect(hasFocus(tester, addItemField()), isTrue,
          reason: '父页面 onChanged 重载后焦点仍要留在「添加一项」');

      final slip = (await JadeSlipService.instance.list()).single;
      expect(slip.items.map((i) => i.text), ['第一项']);
    });
  },
      // 宽屏分栏靠 LayoutUtils.isDesktopLayout（真实 Platform.isMacOS），
      // CI 跑在 Linux，这里只在 macOS 本地生效。
      skip: !Platform.isMacOS);
}
