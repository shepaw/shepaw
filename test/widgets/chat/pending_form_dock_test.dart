import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/pending_form_dock.dart';

Message _msg(String id, {Map<String, dynamic>? form}) => Message(
      id: id,
      from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
      type: MessageType.text,
      content: form?['title']?.toString() ?? 'hi',
      timestampMs: 0,
      metadata: form == null ? null : {'form': form},
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

void main() {
  group('dockedPendingForm', () {
    test('取最新一张还开着的主机提问卡', () {
      final docked = dockedPendingForm([
        _msg('a', form: _form('f1')),
        _msg('b'),
        _msg('c', form: _form('f2')),
        _msg('d'),
      ]);
      expect(docked?.id, 'c');
    });

    test('答过、作废的不算；deferred 的还能答', () {
      expect(
        dockedPendingForm([
          _msg('a', form: _form('f1', extra: {'submitted_values': {}})),
          _msg('b', form: _form('f2', extra: {'closed': 'timeout'})),
        ]),
        isNull,
      );
      expect(
        dockedPendingForm([
          _msg('a', form: _form('f1', extra: {'deferred': true})),
        ])?.id,
        'a',
      );
    });

    test('不是主机提问卡（没有 peer_form）的表单留在消息流里', () {
      final form = _form('f1')..remove('peer_form');
      expect(dockedPendingForm([_msg('a', form: form)]), isNull);
    });
  });

  testWidgets('停靠卡提交时带回原消息，可收起', (tester) async {
    final message = _msg('card', form: _form('f1'));
    Message? submittedFrom;
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PendingFormDock(
            message: message,
            onFormSubmitted: (msg, formId, values, summary) {
              submittedFrom = msg;
              submitted = values;
            },
          ),
        ),
      ),
    ));

    expect(find.text('Claude · 等待你的回答'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3000');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(submittedFrom?.id, 'card');
    expect(submitted, {'port': '3000'});

    await tester.tap(find.text('Claude · 等待你的回答'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });
}
