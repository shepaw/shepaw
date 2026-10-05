import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/widgets/chat/cursor_model_panel.dart';

PeerAgentModel _grok() {
  return PeerAgentModel(
    value: 'grok-4.7',
    displayName: 'Grok 4.7',
    options: const [
      PeerModelOption(
        id: 'fast',
        displayName: 'Fast',
        values: ['false', 'true'],
        defaultValue: 'true',
      ),
      PeerModelOption(
        id: 'context',
        displayName: 'Context',
        values: ['256k', '500k'],
        labels: ['256K', '500K'],
        defaultValue: '256k',
      ),
      PeerModelOption(
        id: 'reasoning_effort',
        displayName: 'Effort',
        values: ['low', 'high'],
        labels: ['Low', 'High'],
        defaultValue: 'high',
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Size surface,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            width: 248,
            child: CursorModelSettings(
              models: [
                _grok(),
                PeerAgentModel(value: 'sonnet', displayName: 'Sonnet'),
              ],
              currentModel: 'grok-4.7',
              optionValues: const {},
              modelLabel: '模型',
              onFastChanged: (_) {},
              onOptionChanged: (_, __) {},
              onModelChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Rect _row(WidgetTester tester, String title) {
  return tester.getRect(
    find.ancestor(
      of: find.text(title),
      matching: find.byType(CompositedTransformTarget),
    ),
  );
}

double _gap(Rect row, Rect menu) {
  if (menu.left >= row.right - 1) return menu.left - row.right;
  return row.left - menu.right;
}

void main() {
  testWidgets('submenu sits against the row and replaces the previous one', (tester) async {
    await _pump(tester, surface: const Size(1200, 800));

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(find.text('500K'), findsOneWidget);

    final contextGap = _gap(_row(tester, 'Context'), tester.getRect(find.text('500K')));
    expect(contextGap, inInclusiveRange(0, 48));

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    expect(find.text('500K'), findsNothing);
    expect(find.text('Sonnet'), findsOneWidget);

    final modelGap = _gap(_row(tester, '模型'), tester.getRect(find.text('Sonnet')));
    expect(modelGap, inInclusiveRange(0, 48));
  });

  testWidgets('narrow layout keeps the submenu next to the panel', (tester) async {
    await _pump(tester, surface: const Size(390, 800));

    await tester.tap(find.text('Effort'));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsOneWidget);

    final gap = _gap(_row(tester, 'Effort'), tester.getRect(find.text('Low')));
    expect(gap, inInclusiveRange(0, 48));

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsNothing);
    expect(find.text('500K'), findsOneWidget);
  });
}
