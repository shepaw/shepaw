import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/chat/plan_approval_card.dart';
import 'package:shepaw/widgets/collapsible_message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CollapsibleMessageBubble goldens', () {
    testWidgets('collapsed shows header only', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: CollapsibleMessageBubble(
                initiallyCollapsed: true,
                title: 'Thinking',
                child: Text(
                  'This body must stay hidden while collapsed.',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(CollapsibleMessageBubble),
        matchesGoldenFile('goldens/collapsible_message_collapsed.png'),
      );
    });

    testWidgets('expanded shows body', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 240));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: CollapsibleMessageBubble(
                initiallyCollapsed: false,
                title: 'Thinking',
                child: Text(
                  'Expanded body content for golden snapshot.',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(CollapsibleMessageBubble),
        matchesGoldenFile('goldens/collapsible_message_expanded.png'),
      );
    });
  });

  group('PlanApprovalCard goldens', () {
    final planData = <String, dynamic>{
      'title': 'Ship launch checklist',
      'summary': 'Approve the ordered tasks below.',
      'tasks': [
        {
          'id': 't1',
          'title': 'Rotate keystore',
          'description': 'Replace leaked Android signing secrets.',
          'assignee': 'ops',
          'dependencies': <String>[],
          'estimated_complexity': 'medium',
          'status': 'pending',
        },
        {
          'id': 't2',
          'title': 'Merge security branch',
          'description': 'Land TLS and Hub auth fixes on main.',
          'assignee': 'dev',
          'dependencies': ['t1'],
          'estimated_complexity': 'high',
          'status': 'pending',
        },
      ],
    };

    testWidgets('pending approval card', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: PlanApprovalCard(
                planData: planData,
                isResponded: false,
                onRespond: (_, {feedback, skippedTaskIds}) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(PlanApprovalCard),
        matchesGoldenFile('goldens/plan_approval_card_pending.png'),
      );
    });

    testWidgets('approved card', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final approved = Map<String, dynamic>.from(planData)..['_approved'] = true;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: PlanApprovalCard(
                planData: approved,
                isResponded: true,
                onRespond: (_, {feedback, skippedTaskIds}) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(PlanApprovalCard),
        matchesGoldenFile('goldens/plan_approval_card_approved.png'),
      );
    });
  });
}
