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
    void Function(String formId, Map<String, dynamic> values, String summary)?
        onSubmitted,
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
              child: FormBubble(
                formData: data,
                onFormSubmitted: onSubmitted,
              ),
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

  bool submitEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '提交'),
    );
    return button.onPressed != null;
  }

  testWidgets('filled required text fields enable submit', (tester) async {
    Map<String, dynamic>? submitted;
    await pumpForm(
      tester,
      data: {
        'form_id': 'new-agent',
        'title': '新建 agent',
        'fields': [
          {
            'type': 'text',
            'name': 'engine',
            'label': '引擎 (engine id)',
            'required': true,
          },
          {
            'type': 'text_input',
            'field_id': 'display_name',
            'label': '显示名',
            'required': 'true',
          },
          {
            'type': 'text_input',
            'field_id': 'cwd',
            'label': '工作目录（须已存在）',
            'required': true,
          },
        ],
      },
      onSubmitted: (_, values, __) => submitted = values,
    );

    expect(submitEnabled(tester), isFalse);

    final inputs = find.byType(TextField);
    await tester.enterText(inputs.at(0), 'claude-code');
    await tester.pump();
    expect(submitEnabled(tester), isFalse);

    await tester.enterText(inputs.at(1), 'website-dev');
    await tester.enterText(inputs.at(2), '~/workspace/shepaw/website');
    await tester.pump();
    expect(submitEnabled(tester), isTrue);

    await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
    await tester.pump();
    expect(submitted, {
      'engine': 'claude-code',
      'display_name': 'website-dev',
      'cwd': '~/workspace/shepaw/website',
    });
  });

  testWidgets('default values count as filled without extra typing', (tester) async {
    await pumpForm(
      tester,
      data: {
        'form_id': 'prefilled',
        'title': '新建 agent',
        'fields': [
          {
            'type': 'text_input',
            'field_id': 'engine',
            'label': '引擎',
            'required': true,
            'default': 'claude-code',
          },
          {
            'type': 'text_input',
            'field_id': 'name',
            'label': '显示名',
            'required': true,
            'value': 'website-dev',
          },
        ],
      },
    );

    expect(find.text('claude-code'), findsOneWidget);
    expect(find.text('website-dev'), findsOneWidget);
    expect(submitEnabled(tester), isTrue);
  });

  testWidgets('select, radio and checkbox satisfy required fields', (tester) async {
    Map<String, dynamic>? submitted;
    String? summary;
    await pumpForm(
      tester,
      width: 480,
      data: {
        'form_id': 'choices',
        'title': '项目设置',
        'fields': [
          {
            'type': 'select',
            'name': 'engine',
            'label': '引擎',
            'required': true,
            'options': ['claude-code', 'cursor'],
          },
          {
            'type': 'radio',
            'name': 'kind',
            'label': '类型',
            'required': true,
            'options': [
              {'value': 'web', 'label': '网站'},
              {'value': 'cli', 'label': '命令行'},
            ],
          },
          {
            'type': 'checkbox',
            'name': 'confirm',
            'label': '目录已存在',
            'required': true,
          },
          {
            'type': 'checkbox',
            'name': 'extras',
            'label': '附加',
            'options': [
              {'id': 'docs', 'label': '文档'},
              {'id': 'tests', 'label': '测试'},
            ],
          },
        ],
      },
      onSubmitted: (_, values, text) {
        submitted = values;
        summary = text;
      },
    );

    expect(find.textContaining('Unknown field type'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));
    expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(3));
    expect(submitEnabled(tester), isFalse);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('claude-code').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('网站'));
    await tester.pump();
    expect(submitEnabled(tester), isFalse);

    await tester.tap(find.textContaining('目录已存在'));
    await tester.pump();
    expect(submitEnabled(tester), isTrue);

    await tester.tap(find.text('文档'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
    await tester.pump();

    expect(submitted?['engine'], 'claude-code');
    expect(submitted?['kind'], 'web');
    expect(submitted?['confirm'], isTrue);
    expect(submitted?['extras'], ['docs']);
    expect(summary, contains('引擎: claude-code'));
    expect(summary, contains('类型: 网站'));
    expect(summary, contains('目录已存在: true'));
    expect(summary, contains('附加: 文档'));
  });
}
