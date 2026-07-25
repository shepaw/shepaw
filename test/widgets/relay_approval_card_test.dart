import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/relay_approval_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message cardMessage(Map<String, dynamic> payload) => Message(
        id: 'appr_dt-1',
        content: '⚠️ codebuddy 请求操作确认',
        timestampMs: 0,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
        metadata: {'relay_approval': payload},
      );

  Map<String, dynamic> basePayload({
    String status = 'pending',
    String? selectedLabel,
    String? errorNote,
  }) =>
      {
        'confirmation_id': 'conf-1',
        'prompt': '允许执行 git push 吗？',
        'actions': const [
          {'id': 'allow', 'label': '允许'},
          {'id': 'deny', 'label': '拒绝'},
        ],
        'agent_id': 'a-1',
        'agent_name': 'codebuddy',
        'relay_channel_id': 'shed_she_ch__a-1',
        'dispatch_task_id': 'dt-1',
        'kind': 'chat',
        'status': status,
        if (selectedLabel != null) 'selected_action_label': selectedLabel,
        if (errorNote != null) 'error_note': errorNote,
      };

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(500, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('RelayApprovalCard', () {
    testWidgets('pending renders prompt and action buttons', (tester) async {
      // pending 态的惰性对齐会尝试读 DB（无插件环境静默失败）→ 保持 pending
      await pump(tester, RelayApprovalCard(message: cardMessage(basePayload())));

      expect(find.text('操作确认 · codebuddy'), findsOneWidget);
      expect(find.text('等待审批'), findsOneWidget);
      expect(find.text('允许执行 git push 吗？'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    });

    testWidgets('resolved renders selected label without buttons',
        (tester) async {
      await pump(
          tester,
          RelayApprovalCard(
              message: cardMessage(
                  basePayload(status: 'resolved', selectedLabel: '允许'))));

      expect(find.text('已处理'), findsOneWidget);
      expect(find.text('你的选择：允许'), findsOneWidget);
      expect(find.text('允许执行 git push 吗？'), findsOneWidget);
      // 不再有操作按钮（"允许"/"拒绝" 按钮文本不应独立出现）
      expect(find.widgetWithText(FilledButton, '允许'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '拒绝'), findsNothing);
    });

    testWidgets('expired renders grey chip and no buttons', (tester) async {
      await pump(tester,
          RelayApprovalCard(message: cardMessage(basePayload(status: 'expired'))));

      expect(find.text('已过期'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '允许'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '拒绝'), findsNothing);
    });

    testWidgets('failed renders error note', (tester) async {
      await pump(
          tester,
          RelayApprovalCard(
              message: cardMessage(basePayload(
                  status: 'failed', errorNote: 'connection lost'))));

      expect(find.text('处理失败'), findsOneWidget);
      expect(find.text('connection lost'), findsOneWidget);
    });
  });
}
