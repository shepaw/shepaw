import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/dispatch_task.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/dispatch_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message statusMessage(Map<String, dynamic> meta) => Message(
        id: 'm-1',
        content: 'status',
        timestampMs: 0,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
        metadata: meta,
      );

  Map<String, dynamic> statusMeta(String status,
          {bool awaiting = false, String confirmTitle = ''}) =>
      {
        'dispatch_status': true,
        'dispatch_task_id': 'dt-1',
        'target_agent_id': 'a-1',
        'target_agent_name': 'codebuddy',
        'target_channel_id': 'dm_user_a1',
        'prompt_preview': 'fix the bug',
        'status': status,
        if (awaiting) 'awaiting_confirmation': true,
        if (confirmTitle.isNotEmpty) 'confirmation_title': confirmTitle,
      };

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(500, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  group('DispatchStatusCard', () {
    testWidgets('running shows agent name, prompt and 执行中 chip',
        (tester) async {
      await pump(tester, DispatchStatusCard(
          message: statusMessage(statusMeta(DispatchTask.statusRunning))));

      expect(find.text('任务派发 · codebuddy'), findsOneWidget);
      expect(find.text('执行中'), findsOneWidget);
      expect(find.text('fix the bug'), findsOneWidget);
      expect(find.text('查看执行详情'), findsOneWidget);
    });

    testWidgets('done shows 已完成 chip', (tester) async {
      await pump(tester, DispatchStatusCard(
          message: statusMessage(statusMeta(DispatchTask.statusDone))));
      expect(find.text('已完成'), findsOneWidget);
    });

    testWidgets('error shows 执行失败 chip', (tester) async {
      await pump(tester, DispatchStatusCard(
          message: statusMessage(statusMeta(DispatchTask.statusError))));
      expect(find.text('执行失败'), findsOneWidget);
    });

    testWidgets('timeout shows 执行超时 chip', (tester) async {
      await pump(tester, DispatchStatusCard(
          message: statusMessage(statusMeta(DispatchTask.statusTimeout))));
      expect(find.text('执行超时'), findsOneWidget);
    });

    testWidgets('awaiting confirmation overrides running state', (tester) async {
      await pump(
          tester,
          DispatchStatusCard(
              message: statusMessage(statusMeta(DispatchTask.statusRunning,
                  awaiting: true, confirmTitle: 'Delete build/ directory'))));

      expect(find.text('等待操作确认'), findsOneWidget);
      expect(find.text('待确认：Delete build/ directory'), findsOneWidget);
      expect(find.text('前往处理确认'), findsOneWidget);
    });
  });

  group('DispatchConfirmCard', () {
    Message confirmMessage(String status) => Message(
          id: 'm-2',
          content: 'confirm',
          timestampMs: 0,
          from: MessageFrom(id: 'system', type: 'system', name: 'System'),
          type: MessageType.system,
          metadata: {
            'dispatch_confirm': {
              'agent_id': 'a-1',
              'agent_name': 'codebuddy',
              'task': 'rm -rf build/ && rebuild',
              'target_channel_id': 'dm_user_a1',
              'timeout_min': 30,
              'status': status,
            },
          },
        );

    testWidgets('pending shows task brief and both buttons', (tester) async {
      await pump(tester, DispatchConfirmCard(message: confirmMessage('pending')));

      expect(find.text('派发确认 · codebuddy'), findsOneWidget);
      expect(find.text('rm -rf build/ && rebuild'), findsOneWidget);
      expect(find.text('等待确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确认派发'), findsOneWidget);
    });

    testWidgets('confirmed hides buttons', (tester) async {
      await pump(
          tester, DispatchConfirmCard(message: confirmMessage('confirmed')));

      expect(find.text('已确认'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.text('确认派发'), findsNothing);
    });

    testWidgets('cancelled hides buttons', (tester) async {
      await pump(
          tester, DispatchConfirmCard(message: confirmMessage('cancelled')));

      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.text('确认派发'), findsNothing);
    });
  });
}
