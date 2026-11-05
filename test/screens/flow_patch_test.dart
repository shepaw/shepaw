import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/widgets/flow/flow_yaml.dart';

const _runYaml = '''
steps:
  - id: build
    seq:
      steps:
        - id: impl
          task: {uses: "agent:x", prompt: "写"}
        - id: review
          task: {uses: "agent:y", prompt: "审"}
''';

/// 嵌套容器：父节点的 key 是完整路径，只有顶层容器才等于 id。
const _nestedYaml = '''
steps:
  - id: outer
    seq:
      steps:
        - id: inner
          seq:
            steps:
              - id: leaf
                task: {uses: "agent:x", prompt: "写"}
''';

/// 运行中的节点上有个不停转的进度圈，pumpAndSettle 永远等不到静止。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('the steps of a container come out as json, a leaf has none', () {
    final steps = FlowYaml.stepsJsonOf(_runYaml, 'build');
    expect(steps, isNotNull);
    final decoded = FlowYaml.stepsFromJson(steps!);
    expect(decoded, isNotNull);
    expect([for (final s in decoded!) s['id']], ['impl', 'review']);
    // 叶子没有子步骤：改写要指向它所在的容器。
    expect(FlowYaml.stepsJsonOf(_runYaml, 'impl'), isNull);
    expect(FlowYaml.stepsJsonOf(_runYaml, 'nope'), isNull);
    // 不是一组步骤就读不回来。
    expect(FlowYaml.stepsFromJson('{"id": "a"}'), isNull);
  });

  testWidgets('a pending container can be rewritten in place', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        Map<String, dynamic>? reply;
        switch (frame['type']) {
          case 'flow_run_get_req':
            reply = {
              'type': 'flow_run_get_resp',
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'yaml': _runYaml,
              'tree': [
                {
                  'key': 'build',
                  'id': 'build',
                  'kind': 'seq',
                  'status': 'running',
                  'children': [
                    {'key': 'build/impl', 'id': 'impl', 'kind': 'task', 'status': 'done'},
                    {'key': 'build/review', 'id': 'review', 'kind': 'task', 'status': 'pending'},
                  ],
                },
              ],
            };
          case 'flow_run_patch_req':
            reply = {
              'type': 'flow_run_patch_resp',
              'success': true,
              'run_id': 'r1',
            };
        }
        if (reply != null) {
          bus.add(PeerControlEvent(
              peerId: peerId, data: {...reply, 'request_id': frame['request_id']}));
        }
        return true;
      },
    );
    // 宽一点才够"桌面"：源码条在窄屏是只读的。
    tester.view.physicalSize = const Size(3000, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: client),
    ));
    await _settle(tester);

    // 打开还没跑到的那个叶子：改写要落到它所在的容器上。
    await tester.tap(find.text('review'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('node-patch')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('node-patch')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('yaml-editor')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('yaml-apply')));
    await _settle(tester);

    final patch = sent.firstWhere((f) => f['type'] == 'flow_run_patch_req');
    // 目标是容器，不是那个叶子。
    expect(patch['node_key'], 'build');
    expect(patch['steps'], isA<List>());
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('a node that already ran has no rewrite entry', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'flow_run_get_resp',
          'request_id': frame['request_id'],
          'success': true,
          'run_id': 'r1',
          'status': 'running',
          'yaml': _runYaml,
          'tree': [
            {'key': 'build/impl', 'id': 'impl', 'kind': 'task', 'status': 'done'},
          ],
        }));
        return true;
      },
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: client),
    ));
    await _settle(tester);
    await tester.tap(find.text('impl'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('node-patch')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('nested container uses the full NodeKey, not the bare id',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        Map<String, dynamic>? reply;
        switch (frame['type']) {
          case 'flow_run_get_req':
            reply = {
              'type': 'flow_run_get_resp',
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'yaml': _nestedYaml,
              'tree': [
                {
                  'key': 'outer',
                  'id': 'outer',
                  'kind': 'seq',
                  'status': 'running',
                  'children': [
                    {
                      'key': 'outer/inner',
                      'id': 'inner',
                      'kind': 'seq',
                      'status': 'pending',
                      'children': [
                        {
                          'key': 'outer/inner/leaf',
                          'id': 'leaf',
                          'kind': 'task',
                          'status': 'pending',
                        },
                      ],
                    },
                  ],
                },
              ],
            };
          case 'flow_run_patch_req':
            reply = {
              'type': 'flow_run_patch_resp',
              'success': true,
              'run_id': 'r1',
            };
        }
        if (reply != null) {
          bus.add(PeerControlEvent(
              peerId: peerId, data: {...reply, 'request_id': frame['request_id']}));
        }
        return true;
      },
    );
    tester.view.physicalSize = const Size(3000, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: client),
    ));
    await _settle(tester);

    await tester.tap(find.text('leaf'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('node-patch')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('node-patch')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('yaml-editor')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('yaml-apply')));
    await _settle(tester);

    final patch = sent.firstWhere((f) => f['type'] == 'flow_run_patch_req');
    // 主机按 `NodeKey::parse` 找节点，只发 `inner` 会记到一个用不上的 key 上。
    expect(patch['node_key'], 'outer/inner');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
