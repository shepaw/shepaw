import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_artifact_card.dart';

const _runScope = 'flow:fl_1:instance:in_1:run:run_1';
const _instanceScope = 'flow:fl_1:instance:in_1';

List<FlowArtifact> _runArtifacts() => FlowArtifact.listFromResponse({
      'artifacts': [
        {
          'artifact_id': 'art_1',
          'title': '设计报告',
          'kind': 'report',
          'latest_version': 2,
          'scope': _runScope,
          'pouch_id': 'p1',
          'versions': [
            {
              'version': 1,
              'filename': 'draft.md',
              'hash': 'h1',
              'size': 1024,
              'created_ms': 1700000000000,
              'uri': 'pouch://p1/$_runScope/artifacts/art_1/v1/draft.md',
            },
            {
              'version': 2,
              'filename': 'final.md',
              'hash': 'h2',
              'size': 2048,
              'created_ms': 1700000005000,
              'note': '终稿',
              'uri': 'pouch://p1/$_runScope/artifacts/art_1/v2/final.md',
            },
          ],
        },
      ],
    });

List<FlowArtifact> _instanceArtifacts() => FlowArtifact.listFromResponse({
      'artifacts': [
        {
          'artifact_id': 'art_1',
          'title': '已提升报告',
          'kind': 'report',
          'latest_version': 7,
          'scope': _instanceScope,
          'pouch_id': 'p1',
          'versions': [
            {
              'version': 7,
              'filename': 'promoted.md',
              'hash': 'h7',
              'size': 4096,
              'created_ms': 1700000009000,
              'uri':
                  'pouch://p1/$_instanceScope/artifacts/art_1/v7/promoted.md',
            },
          ],
        },
      ],
    });

Widget _app(FlowArtifactCard card) => MaterialApp(
      locale: const Locale('en'),
      home: Scaffold(
        body: SingleChildScrollView(child: card),
      ),
    );

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('empty card is compact and hides instance switch on old hosts',
      (tester) async {
    _setViewport(tester);
    await tester.pumpWidget(_app(const FlowArtifactCard()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('flow-artifact-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-artifact-empty')), findsOneWidget);
    expect(find.text('还没有产物'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('flow-artifact-tab-instance')), findsNothing);
  });

  testWidgets('loaded card groups versions, expands details and opens URI',
      (tester) async {
    _setViewport(tester);
    final opened = <String>[];
    var scopeChanges = 0;
    await tester.pumpWidget(_app(FlowArtifactCard(
      artifacts: _runArtifacts(),
      instanceArtifacts: _instanceArtifacts(),
      instanceScopeAvailable: true,
      onScopeChanged: (_) => scopeChanges++,
      onOpenUri: (context, uri) async => opened.add(uri),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('flow-artifact-empty')), findsNothing);
    expect(find.text('设计报告'), findsOneWidget);
    expect(find.text('v2'), findsOneWidget);
    expect(find.textContaining('final.md'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);

    const v2Key = ValueKey('flow-artifact-version-art_1|2|final.md');
    await tester.tap(find.byKey(v2Key));
    await tester.pumpAndSettle();
    expect(opened, [
      'pouch://p1/$_runScope/artifacts/art_1/v2/final.md',
    ]);

    await tester.tap(
        find.byKey(const ValueKey('flow-artifact-toggle-art_1|2|final.md')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SHA256：h2'), findsOneWidget);
    expect(find.textContaining('备注：终稿'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('flow-artifact-tab-instance')));
    await tester.pumpAndSettle();
    expect(scopeChanges, 1);
    expect(find.text('已提升报告'), findsOneWidget);
    expect(find.text('v7'), findsOneWidget);
  });

  testWidgets('失败态保留已有产物并给重试入口', (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlowArtifactCard(
          artifacts: _runArtifacts(),
          failed: true,
          onRetry: () => retries++,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('设计报告'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-artifact-failed')), findsOneWidget);
    expect(find.text('产物加载失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-artifact-empty')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flow-artifact-retry')));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });
}
