import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';

const _yaml = 'steps:\n- id: impl\n  task: {prompt: 写}\n'
    '- id: review\n  task: {prompt: 审}\n';

/// 假主机：按帧类型回包（读流程 / 字段表 / 校验）。
HubFlow _host(StreamController<PeerControlEvent> bus) => HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        Map<String, dynamic>? reply;
        switch (frame['type']) {
          case 'flow_get_req':
            reply = {
              'type': 'flow_get_resp',
              'success': true,
              'revision': 2,
              'yaml': _yaml,
            };
          case 'flow_schema_req':
            reply = {
              'type': 'flow_schema_resp',
              'success': true,
              'common': <Object>[],
              'kinds': <String, Object>{},
            };
          case 'flow_validate_req':
            reply = {
              'type': 'flow_validate_resp',
              'success': true,
              'yaml': _yaml,
              'tree': [
                {'key': 'impl', 'id': 'impl', 'kind': 'task'},
                {'key': 'review', 'id': 'review', 'kind': 'task'},
              ],
              'diagnostics': <Object>[],
            };
        }
        if (reply != null) {
          bus.add(PeerControlEvent(
              peerId: peerId,
              data: {...reply, 'request_id': frame['request_id']}));
        }
        return true;
      },
    );

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('点选节点后说话：带上 flow.ref 和 selection 发给群主', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      // group: scope 本身就是群：说话发到这个群。
      scope: 'group:g1',
      client: _host(bus),
      talk: (
          {required groupId,
          required content,
          required flowContext,
          required onChunk}) async {
        sent.add({
          'group_id': groupId,
          'content': content,
          ...flowContext,
        });
        onChunk('改好了：评审换成 Codex。');
      },
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('talk-input')), findsOneWidget);
    // 长按选中一个节点 → 出现芯片。
    await tester.longPress(find.text('review'));
    await tester.pump();
    expect(find.byKey(const ValueKey('sel-review')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('talk-input')), '评审换成 Codex');
    await tester.tap(find.byKey(const ValueKey('talk-send')));
    await _settle(tester);

    expect(sent, hasLength(1));
    final frame = sent.single;
    expect(frame['group_id'], 'g1');
    expect(frame['content'], '评审换成 Codex');
    // 群主靠这两个字段知道改哪儿：引用 + 选中的 id。
    expect(frame['flow'], {'ref': 'group:g1/dev'});
    expect(frame['selection'], ['review']);
    expect(find.textContaining('改好了'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('没有群时不画说话条', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: _host(bus),
      talk: ({
        required groupId,
        required content,
        required flowContext,
        required onChunk,
      }) async {
        fail('没有群就不该发');
      },
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('talk-input')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
