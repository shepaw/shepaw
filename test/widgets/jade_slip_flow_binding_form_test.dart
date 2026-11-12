import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/widgets/jade_slip_flow_binding.dart';

/// 预设表单的「回显」判断：保存途中的旧绑定不抢走输入，父页面确认之后
/// 外部退回到以前见过的某一版也要照常采纳。
void main() {
  const a = JadeSlipFlowBinding(
    scope: 'lib',
    name: '发布流程',
    inputs: {'goal': 'A'},
  );

  Widget host(JadeSlipFlowBinding binding, ValueChanged<JadeSlipFlowBinding> onChanged) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: JadeSlipFlowBindingForm(
            binding: binding,
            inputNames: const ['goal'],
            onChanged: onChanged,
          ),
        ),
      );

  String goalText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('slip-flow-input-goal')))
      .controller!
      .text;

  testWidgets('保存途中的旧绑定是回显；确认后外部退回旧版要采纳', (tester) async {
    JadeSlipFlowBinding? emitted;
    await tester.pumpWidget(host(a, (b) => emitted = b));
    expect(goalText(tester), 'A');

    await tester.enterText(
        find.byKey(const ValueKey('slip-flow-input-goal')), 'B');
    await tester.pump();
    expect(emitted?.inputs['goal'], 'B');

    // 父页面保存途中用旧绑定 A 重建：是回显，不抢走正在输入的 B。
    await tester.pumpWidget(host(a, (b) => emitted = b));
    expect(goalText(tester), 'B');

    // 父页面确认收到 B。
    await tester.pumpWidget(host(emitted!, (b) => emitted = b));
    expect(goalText(tester), 'B');

    // 另一台设备 / 主机回写把绑定退回到 A：外部改动，必须采纳。
    await tester.pumpWidget(host(a, (b) => emitted = b));
    expect(goalText(tester), 'A');
  });
}
