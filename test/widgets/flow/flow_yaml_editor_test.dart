import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/flow/flow_yaml_editor.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: child)),
    );

void main() {
  testWidgets('人没改过源码时，输入框跟上新草稿', (tester) async {
    var yaml = 'a: 1\n';
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          TextButton(
            onPressed: () => setState(() => yaml = 'a: 2\n'),
            child: const Text('next'),
          ),
          Expanded(child: FlowYamlEditor(yaml: yaml)),
        ],
      ),
    )));

    expect(tester.widget<TextField>(find.byKey(const ValueKey('yaml-editor'))).controller?.text,
        'a: 1\n');
    await tester.tap(find.text('next'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('yaml-editor'))).controller?.text,
        'a: 2\n');
  });

  testWidgets('源码里改过的字不会被新草稿盖掉', (tester) async {
    var yaml = 'a: 1\n';
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          TextButton(
            onPressed: () => setState(() => yaml = 'a: 2\n'),
            child: const Text('next'),
          ),
          Expanded(child: FlowYamlEditor(yaml: yaml)),
        ],
      ),
    )));

    await tester.enterText(find.byKey(const ValueKey('yaml-editor')), 'a: 9\n');
    await tester.tap(find.text('next'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('yaml-editor'))).controller?.text,
        'a: 9\n');
  });
}
