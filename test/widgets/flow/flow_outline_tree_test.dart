import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_outline.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_outline_tree.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  final tree = [
    FlowNode(key: 'a', id: 'a', kind: 'task'),
    FlowNode(key: 'b', id: 'b', kind: 'task'),
  ];

  testWidgets('flashId 让那一行高亮，且每行都能拿到 GlobalKey 供滚动定位', (tester) async {
    final rows = buildFlowOutline(tree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    await tester.pumpWidget(_app(FlowOutlineTree(
      rows: rows,
      canEdit: false,
      rowKeys: keys,
      flashId: 'b',
    )));
    await tester.pump();

    for (final entry in keys.entries) {
      expect(entry.value.currentContext, isNotNull, reason: entry.key);
    }
    final containers = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(containers.length, 2);
    final scheme = Theme.of(tester.element(find.byType(FlowOutlineTree))).colorScheme;
    final flashing = containers.last.decoration! as BoxDecoration;
    expect(flashing.border!.top.color, scheme.primary);
    expect(flashing.border!.top.width, 2);
  });
}
