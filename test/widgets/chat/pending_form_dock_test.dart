import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/paged_form_panel.dart';
import 'package:shepaw/widgets/chat/pending_form_dock.dart';

Message _msg(String id, {Map<String, dynamic>? metadata}) => Message(
      id: id,
      from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
      type: MessageType.text,
      content: 'hi',
      timestampMs: 0,
      metadata: metadata,
    );

Map<String, dynamic> _form(String id, {Map<String, dynamic> extra = const {}}) => {
      'form_id': id,
      'title': '选哪个端口',
      'fields': [
        {'field_id': 'port', 'type': 'text_input', 'label': '端口'},
      ],
      'peer_form': {'peer_id': 'peer-1', 'approval_id': id},
      ...extra,
    };

Map<String, dynamic> _approval(String id,
        {Map<String, dynamic> extra = const {}}) =>
    {
      'confirmation_id': id,
      'prompt': '允许运行 ls 吗',
      'actions': [
        {'id': 'allow', 'label': '允许', 'style': 'primary'},
        {'id': 'deny', 'label': '拒绝'},
      ],
      ...extra,
    };

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    );

void main() {
  group('dockedPendingInteraction', () {
    test('取最新一张待处理卡：提问或审批', () {
      final messages = [
        _msg('a', metadata: {'form': _form('f1')}),
        _msg('b', metadata: {'action_confirmation': _approval('c1')}),
        _msg('c'),
      ];
      final docked =
          dockedPendingInteraction(messages, approvalIsLive: (_) => true);
      expect(docked?.message.id, 'b');
      expect(docked?.kind, DockedInteractionKind.approval);

      // 没人在等的审批卡（历史里没收场的旧卡）不停靠，退到下一张提问卡。
      final stale =
          dockedPendingInteraction(messages, approvalIsLive: (_) => false);
      expect(stale?.message.id, 'a');
      expect(dockedPendingInteraction(messages)?.message.id, 'a');
    });

    test('答过、作废的不算；deferred 的提问还能答', () {
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {
            'form': _form('f1', extra: {'submitted_values': {}})
          }),
          _msg('b', metadata: {
            'form': _form('f2', extra: {'closed': 'timeout'})
          }),
          _msg('c', metadata: {
            'action_confirmation':
                _approval('c1', extra: {'selected_action_id': 'allow'})
          }),
          _msg('d', metadata: {
            'action_confirmation': _approval('c2', extra: {'closed': 'timeout'})
          }),
        ], approvalIsLive: (_) => true),
        isNull,
      );
      final deferred = dockedPendingInteraction([
        _msg('a', metadata: {
          'form': _form('f1', extra: {'deferred': true})
        }),
      ]);
      expect(deferred?.message.id, 'a');
      expect(deferred?.isForm, isTrue);
    });

    test('工作流审批留在原处', () {
      expect(
        dockedPendingInteraction([
          _msg('b', metadata: {
            'action_confirmation':
                _approval('c1', extra: {'_workflowPeerApproval': true})
          }),
        ], approvalIsLive: (_) => true),
        isNull,
      );
    });

    test('气泡上的表单（She 的 form 工具）也停靠，用户接着说话后就不再停靠', () {
      final form = _form('f1')..remove('peer_form');
      final docked = dockedPendingInteraction([
        _msg('a', metadata: {'form': form}),
      ]);
      expect(docked?.message.id, 'a');
      expect(isStandaloneFormCard(docked!.message), isFalse);

      final user = Message(
        id: 'u',
        from: MessageFrom(id: 'me', type: 'user', name: '我'),
        type: MessageType.text,
        content: '算了不填了',
        timestampMs: 1,
      );
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {'form': form}),
          user,
        ]),
        isNull,
      );

      // 主机提问卡由主机收场，用户说过话也照样停靠。
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {'form': _form('f2')}),
          user,
        ])?.message.id,
        'a',
      );
    });

    test('单选、多选、上传卡也停靠，答过的不算', () {
      final single = {
        'select_id': 's1',
        'prompt': '用哪个库？',
        'options': [
          {'id': 'pg', 'label': 'Postgres'},
        ],
      };
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {'single_select': single}),
        ])?.kind,
        DockedInteractionKind.singleSelect,
      );
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {
            'single_select': {...single, 'selected_option_id': 'pg'},
          }),
          _msg('b', metadata: {
            'multi_select': {'select_id': 'm1', 'selected_option_ids': []},
          }),
          _msg('c', metadata: {
            'file_upload': {'upload_id': 'u1', 'closed': 'timeout'},
          }),
        ]),
        isNull,
      );
      expect(
        dockedPendingInteraction([
          _msg('a', metadata: {
            'file_upload': {'upload_id': 'u1', 'prompt': '传张图'},
          }),
        ])?.kind,
        DockedInteractionKind.fileUpload,
      );
    });
  });

  group('PagedFormPanel', () {
    Map<String, dynamic> twoQuestions() => {
          'form_id': 'f1',
          'fields': [
            {
              'field_id': 'question_0',
              'type': 'single_select',
              'label': '用哪个库？',
              'options': [
                {'id': 'Postgres', 'label': 'Postgres'},
                {'id': 'SQLite', 'label': 'SQLite'},
              ],
            },
            {
              'field_id': 'question_1',
              'type': 'text_input',
              'label': '还有别的要说的吗？',
            },
          ],
        };

    ElevatedButton submitButton(WidgetTester tester) => tester.widget(
        find.ancestor(
            of: find.text('提交'), matching: find.byType(ElevatedButton)));

    testWidgets('点选项切到下一题，可退回上一题，答完才能提交', (tester) async {
      Map<String, dynamic>? submitted;
      String? summary;
      await tester.pumpWidget(_app(PagedFormPanel(
        formData: twoQuestions(),
        onFormSubmitted: (formId, values, s) async {
          submitted = values;
          summary = s;
        },
      )));

      expect(find.text('用哪个库？'), findsOneWidget);
      expect(submitButton(tester).onPressed, isNull);

      await tester.tap(find.text('SQLite'));
      await tester.pumpAndSettle();
      expect(find.text('还有别的要说的吗？'), findsOneWidget);
      expect(find.text('用哪个库？'), findsNothing);
      expect(submitButton(tester).onPressed, isNull);

      await tester.tap(find.text('上一题'));
      await tester.pumpAndSettle();
      expect(find.text('用哪个库？'), findsOneWidget);

      // 选中的答案还在；改选最后一题以外的单选也会自动前进。
      await tester.tap(find.text('Postgres'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '没有了');
      await tester.pump();
      expect(submitButton(tester).onPressed, isNotNull);

      await tester.tap(find.text('提交'));
      await tester.pump();
      expect(submitted, {'question_0': 'Postgres', 'question_1': '没有了'});
      expect(summary, '用哪个库？: Postgres; 还有别的要说的吗？: 没有了');
    });

    testWidgets('点题号直接跳转', (tester) async {
      await tester.pumpWidget(_app(PagedFormPanel(
        formData: twoQuestions(),
        onFormSubmitted: (_, __, ___) async {},
      )));
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(find.text('还有别的要说的吗？'), findsOneWidget);
    });

    testWidgets('明确可空的题不挡提交；必勾的勾选题要勾上', (tester) async {
      await tester.pumpWidget(_app(PagedFormPanel(
        formData: {
          'form_id': 'f2',
          'fields': [
            {
              'field_id': 'note',
              'type': 'text_input',
              'label': '备注',
              'required': 'false',
            },
            {
              'field_id': 'agree',
              'type': 'checkbox',
              'label': '同意',
              'required': true,
            },
          ],
        },
        onFormSubmitted: (_, __, ___) async {},
      )));
      expect(submitButton(tester).onPressed, isNull);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(submitButton(tester).onPressed, isNotNull);
    });

    testWidgets('提交还没结束时按钮是忙碌态，不会重复提交', (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(_app(PagedFormPanel(
        formData: {
          'form_id': 'f3',
          'fields': [
            {'field_id': 'port', 'type': 'text_input', 'label': '端口'},
          ],
        },
        onFormSubmitted: (_, __, ___) {
          calls++;
          return pending.future;
        },
      )));
      await tester.enterText(find.byType(TextField), '3000');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pump();
      expect(submitButton(tester).onPressed, isNull);
      await tester.tap(find.text('提交'));
      await tester.pump();
      expect(calls, 1);

      pending.complete();
      await tester.pump();
      expect(submitButton(tester).onPressed, isNotNull);
    });

    test('有分页不认识的字段时退回平铺表单', () {
      expect(PagedFormPanel.supports(twoQuestions()), isTrue);
      expect(
        PagedFormPanel.supports({
          'fields': [
            {'field_id': 'f', 'type': 'file_upload'},
          ],
        }),
        isFalse,
      );
    });
  });

  testWidgets('停靠的提问卡提交时带回原消息，可收起', (tester) async {
    final message = _msg('card', metadata: {'form': _form('f1')});
    Message? submittedFrom;
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(_app(PendingInteractionDock(
      interaction: DockedInteraction(message, DockedInteractionKind.form),
      onFormSubmitted: (msg, formId, values, summary) async {
        submittedFrom = msg;
        submitted = values;
      },
      onActionSelected: (_, __, ___, ____) {},
    )));

    expect(find.text('Claude · 等待你的回答'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3000');
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(submittedFrom?.id, 'card');
    expect(submitted, {'port': '3000'});

    await tester.tap(find.text('Claude · 等待你的回答'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('停靠的单选卡点选项带回原消息', (tester) async {
    final message = _msg('pick', metadata: {
      'single_select': {
        'select_id': 's1',
        'prompt': '用哪个库？',
        'options': [
          {'id': 'pg', 'label': 'Postgres'},
          {'id': 'lite', 'label': 'SQLite'},
        ],
      },
    });
    String? picked;
    await tester.pumpWidget(_app(PendingInteractionDock(
      interaction:
          DockedInteraction(message, DockedInteractionKind.singleSelect),
      onFormSubmitted: (_, __, ___, ____) async {},
      onSingleSelectSubmitted: (msg, selectId, optionId, label) {
        picked = '${msg.id}/$selectId/$optionId';
      },
      onActionSelected: (_, __, ___, ____) {},
    )));

    expect(find.text('Claude · 等待你的回答'), findsOneWidget);
    expect(find.text('用哪个库？'), findsOneWidget);
    await tester.tap(find.text('SQLite'));
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(picked, 'pick/s1/lite');
  });

  testWidgets('停靠的审批卡点按钮带回原消息和选项', (tester) async {
    final message =
        _msg('host', metadata: {'action_confirmation': _approval('c1')});
    String? picked;
    await tester.pumpWidget(_app(PendingInteractionDock(
      interaction: DockedInteraction(message, DockedInteractionKind.approval),
      onFormSubmitted: (_, __, ___, ____) async {},
      onActionSelected: (msg, confirmationId, actionId, label) {
        picked = '${msg.id}/$confirmationId/$actionId';
      },
    )));

    expect(find.text('Claude · 等待你的确认'), findsOneWidget);
    await tester.tap(find.text('允许'));
    await tester.pump();
    expect(picked, 'host/c1/allow');
  });
}
