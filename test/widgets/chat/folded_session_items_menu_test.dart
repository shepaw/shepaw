import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/widgets/chat/folded_session_items.dart';

/// 主机端折叠会话分页的假实现：请求发出去后异步回一页。
HubFoldedSessions _client(StreamController<PeerControlEvent> bus) =>
    HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'agent_sessions_req') {
          scheduleMicrotask(() {
            if (bus.isClosed) return;
            bus.add(PeerControlEvent(
              peerId: peerId,
              data: {
                'type': 'agent_sessions_resp',
                'request_id': frame['request_id'],
                'sessions': [
                  {
                    'session_id': 'flow_deadbe12_impl',
                    'title': 'Impl',
                    'updated_at': 1,
                    'source': 'hub',
                    'origin': {'kind': 'flow', 'run_id': 'deadbe12'},
                  },
                ],
                'cursor': '',
              },
            ));
          });
        }
        return true;
      },
    );

void main() {
  testWidgets('A4-5: 菜单打开期间行被卸载，不抛异常也不回调', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    final client = _client(bus);

    var viewed = 0;
    final visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (context, show, _) => Scaffold(
          body: show
              ? SessionFolderItems(
                  peerId: 'p1',
                  agentId: 'agent-7',
                  folder: SessionFolderKind.flow,
                  client: client,
                  onViewRun: (_) => viewed++,
                )
              : const SizedBox(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final row = find.text('Impl');
    expect(row, findsOneWidget);

    // 桌面端悬停才显示「更多」。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(row));
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('查看运行'), findsOneWidget);

    // 菜单还开着时把列表换掉：行被卸载，showMenu 返回时 context 已失效。
    visible.value = false;
    await tester.pumpAndSettle();

    await tester.tap(find.text('查看运行'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'await showMenu 之后必须先查 context.mounted');
    expect(viewed, 0, reason: '行已卸载，不能再回调 onViewRun');
  });
}
