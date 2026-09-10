import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/form_bubble.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 群聊表单在窄宽度下必须换行，不能把气泡撑出父级（PC 端 RenderFlex overflow）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const narrow = Size(360, 900);

  const longLabel =
      '1.具體隱藏/下線了哪些 agent 引擎？（能寫名字就寫，寫不全就留空，我讓 agent-bridge 清單';

  Map<String, dynamic> formData({
    Map<String, dynamic>? submittedValues,
    bool required = true,
  }) =>
      {
        'form_id': 'form-1',
        'title': '澄清：agent-bridge 隱藏引擎 → 官網同步調整',
        'description':
            '這項改動我需要一個信息才能準確派活（agent-bridge 改 + website 同步）：',
        'fields': [
          {
            'type': 'text_input',
            'field_id': 'q1',
            'label': longLabel,
            'required': required,
            'placeholder': '例如：Cursor、Windsurf、Aider.. （不確定可直接留空）',
          },
          {
            'type': 'multi_select',
            'field_id': 'q2',
            'label': '2.官網需要跟著改哪些位置？',
            'required': true,
            'options': [
              {'id': 'a', 'label': '首頁「支持的 agent 引擎」展示區'},
              {'id': 'b', 'label': '產品文檔 / 接指指南'},
              {'id': 'c', 'label': '下載 / 安裝導頁'},
              {'id': 'd', 'label': '定價 / 能力對比表'},
            ],
          },
        ],
        if (submittedValues != null) 'submitted_values': submittedValues,
      };

  Future<void> pumpForm(
    WidgetTester tester, {
    required Map<String, dynamic> data,
    double width = 360,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, narrow.height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: FormBubble(formData: data),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('long field label wraps instead of overflowing', (tester) async {
    await pumpForm(tester, data: formData());

    expect(tester.takeException(), isNull);
    expect(find.textContaining('agent-bridge'), findsWidgets);
    expect(find.textContaining('清單'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('required mark stays with wrapping label', (tester) async {
    await pumpForm(tester, data: formData(required: true));

    expect(tester.takeException(), isNull);
    expect(find.textContaining(' *', findRichText: true), findsWidgets);
  });

  testWidgets('submitted long label and value stay within width', (tester) async {
    await pumpForm(
      tester,
      data: formData(
        submittedValues: {
          'q1': 'Cursor、Windsurf、以及一长串补充说明用来确认提交态也不会撑破气泡',
          'q2': ['a', 'd'],
        },
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('清單'), findsOneWidget);
  });

  testWidgets('group sticky message bubble keeps long form inside parent',
      (tester) async {
    await tester.binding.setSurfaceSize(narrow);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: narrow.width,
            child: MessageBubble(
              message: Message(
                id: 'm-form',
                content: '我先看看現有的產物，再決定怎麼派活。',
                timestampMs: 0,
                from: MessageFrom(id: 'a-1', type: 'agent', name: '惜寶'),
                type: MessageType.text,
                metadata: {'form': formData()},
              ),
              isMyMessage: false,
              showAvatar: true,
              showSenderName: true,
              stickySenderName: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final form = find.byType(FormBubble);
    expect(form, findsOneWidget);
    final formWidth = tester.getSize(form).width;
    expect(formWidth, lessThanOrEqualTo(narrow.width));
    expect(formWidth, greaterThan(200));
  });
}
