import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/screens/flow_start_screen.dart';

/// 开跑表单页（玉简 4ecee6ee）：独立页面、长文本自动长高。
void main() {
  const yaml = '''
flow: dev
inputs:
  goal: {type: string, required: true}
  note: {type: string}
  rounds: {type: int, default: 2}
roles:
  coder: {desc: 写}
steps:
  - id: impl
    task: {role: coder, prompt: 写}
''';

  /// 用一个按钮 push 页面，好把返回值收回来；返回 null 就是取消。
  Future<void> pumpLauncher(
    WidgetTester tester, {
    required void Function(FlowStartPlan? plan) onResult,
    GlobalKey<NavigatorState>? navigatorKey,
    String scope = 'lib',
    bool dirty = false,
    Map<String, String> roleDefaults = const {},
    Map<String, String> initialInputs = const {},
    Map<String, String> initialBindings = const {},
    Future<String?> Function()? onPickAgent,
  }) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final plan = await pushFlowStartScreen(
                  context,
                  flowName: 'dev',
                  yaml: yaml,
                  roles: const ['coder'],
                  roleDefaults: roleDefaults,
                  dirty: dirty,
                  scope: scope,
                  revision: 3,
                  initialInputs: initialInputs,
                  initialBindings: initialBindings,
                  onPickAgent: onPickAgent,
                );
                onResult(plan);
              },
              child: const Text('打开'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  testWidgets('是独立页面而不是弹窗，输入框随内容自动长高', (tester) async {
    FlowStartPlan? plan;
    await pumpLauncher(tester, onResult: (p) => plan = p);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(FlowStartScreen), findsOneWidget);
    expect(find.text('运行 dev'), findsOneWidget);

    final goal = find.byKey(const ValueKey('start-input-goal'));
    final note = find.byKey(const ValueKey('start-input-note'));
    final rounds = find.byKey(const ValueKey('start-input-rounds'));
    expect(tester.widget<TextField>(goal).maxLines, isNull);
    expect(tester.widget<TextField>(goal).minLines, 1);
    expect(tester.widget<TextField>(note).maxLines, isNull);
    // 数字输入还是单行，别让软键盘变成回车换行。
    expect(tester.widget<TextField>(rounds).maxLines, 1);

    final before = tester.getSize(goal).height;
    await tester.enterText(goal, '第一行\n第二行\n第三行\n第四行');
    await tester.pump();
    expect(tester.getSize(goal).height, greaterThan(before),
        reason: '多行内容要把输入框撑高，不能只显示一行');

    // 必填没填时不许开跑。
    await tester.enterText(goal, '  ');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pump();
    expect(find.text('「goal」是必填的'), findsOneWidget);
    expect(plan, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('填完多行文本、选好 Agent 才返回计划', (tester) async {
    FlowStartPlan? plan;
    await pumpLauncher(
      tester,
      onResult: (p) => plan = p,
      onPickAgent: () async => 'claude-main',
    );

    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '  第一行\n第二行  ');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pump();
    // 角色没绑 Agent，先拦下来。
    expect(find.text('角色「coder」还没选 Agent'), findsOneWidget);
    expect(plan, isNull);

    await tester.tap(find.byKey(const ValueKey('start-role-coder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pumpAndSettle();

    expect(plan, isNotNull);
    expect(plan!.inputs['goal'], '第一行\n第二行',
        reason: '两端空白去掉，中间的换行要留下');
    expect(plan!.bindings, {'coder': 'claude-main'});
    expect(plan!.saveFirst, isFalse);
    // 页面已经退掉，回到启动页。
    expect(find.byType(FlowStartScreen), findsNothing);
  });

  testWidgets('取消 / 系统返回键都返回 null，不发计划', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var returned = false;
    FlowStartPlan? plan;
    await pumpLauncher(
      tester,
      navigatorKey: navigatorKey,
      onResult: (p) {
        returned = true;
        plan = p;
      },
    );

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(plan, isNull);
    expect(find.byType(FlowStartScreen), findsNothing);

    // 再开一次，这次走系统返回键（Navigator.maybePop）。
    returned = false;
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.byType(FlowStartScreen), findsOneWidget);
    expect(await navigatorKey.currentState!.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(plan, isNull);
    expect(find.byType(FlowStartScreen), findsNothing);
  });

  testWidgets('roles.default 预填后不用手选 Agent', (tester) async {
    FlowStartPlan? plan;
    await pumpLauncher(
      tester,
      onResult: (p) => plan = p,
      roleDefaults: const {'coder': 'codex-main'},
    );
    expect(find.text('codex-main'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '目标');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pumpAndSettle();
    expect(plan?.bindings, {'coder': 'codex-main'});
  });

  testWidgets('群库流程：角色只读显示，开跑不带 bindings', (tester) async {
    FlowStartPlan? plan;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async {
                plan = await pushFlowStartScreen(
                  context,
                  flowName: 'dev',
                  yaml: yaml,
                  roles: const ['coder'],
                  roleDefaults: const {},
                  dirty: false,
                  scope: 'group:g1',
                  revision: 1,
                );
              },
              child: const Text('打开'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.text('由群成员角色自动绑定'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-role-coder')));
    await tester.pump();
    // 只读行点了也不会弹选择器（这里没有 onPickAgent）。
    expect(find.text('由群成员角色自动绑定'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '目标');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pumpAndSettle();
    expect(plan, isNotNull);
    expect(plan!.bindings, isEmpty);
  });

  testWidgets('有未保存草稿：可勾选先保存再跑', (tester) async {
    FlowStartPlan? plan;
    await pumpLauncher(
      tester,
      onResult: (p) => plan = p,
      dirty: true,
      roleDefaults: const {'coder': 'codex-main'},
    );

    expect(find.text('开跑用的是库里保存的第 3 版，不是你正在改的草稿'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-first')));
    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '目标');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pumpAndSettle();
    expect(plan?.saveFirst, isTrue);
  });

  testWidgets('改了字段就撤掉上一条校验提示', (tester) async {
    await pumpLauncher(tester, onResult: (_) {});

    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pump();
    expect(find.text('「goal」是必填的'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '补上了');
    await tester.pump();
    expect(find.text('「goal」是必填的'), findsNothing,
        reason: '修好之后不能还挂着红字');
  });

  testWidgets('重开表单带回上一轮填过的 inputs / bindings', (tester) async {
    FlowStartPlan? plan;
    await pumpLauncher(
      tester,
      onResult: (p) => plan = p,
      initialInputs: const {'goal': '上一轮的目标', 'note': '备注'},
      initialBindings: const {'coder': 'codex-main'},
    );

    expect(find.text('上一轮的目标'), findsOneWidget);
    expect(find.text('备注'), findsOneWidget);
    expect(find.text('codex-main'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await tester.pumpAndSettle();
    expect(plan?.inputs['goal'], '上一轮的目标');
    expect(plan?.inputs['note'], '备注');
    expect(plan?.bindings, {'coder': 'codex-main'},
        reason: '预填的旧绑定不能在第二轮提交时丢掉');
  });
}
