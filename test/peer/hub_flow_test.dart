import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  designModelTests();
  test('frames carry the wire fields and drop empty optionals', () {
    expect(HubFlow.listFrame('', requestId: 'r'),
        {'type': 'flow_list_req', 'request_id': 'r'});
    expect(
        HubFlow.getFrame('bugfix', scope: 'lib', revision: 2, requestId: 'r'), {
      'type': 'flow_get_req',
      'request_id': 'r',
      'scope': 'lib',
      'name': 'bugfix',
      'revision': 2,
    });
    expect(
        HubFlow.startFrame(name: 'bugfix', scope: 'group:g1', inputs: {'a': 1}),
        {
          'type': 'flow_run_start_req',
          'scope': 'group:g1',
          'name': 'bugfix',
          'inputs': {'a': 1},
        });
    expect(HubFlow.gateFrame('run1', 'seq/ok', '通过', requestId: 'r'), {
      'type': 'flow_gate_resp',
      'request_id': 'r',
      'run_id': 'run1',
      'node_key': 'seq/ok',
      'choice': '通过',
    });
  });

  test('every flow frame type is routed as a control frame', () {
    for (final type in [
      'flow_list_resp',
      'flow_run_get_resp',
      'flow_gate_resp',
      'flow_run_patch_resp',
      'flow.run.changed',
      'flow.node.changed',
    ]) {
      expect(PeerConnection.isControlFrameType(type), isTrue, reason: type);
    }
  });

  test('a run response decodes into a nested tree with gate options', () {
    final run = FlowRunView.fromResponse({
      'success': true,
      'run_id': 'r1',
      'status': 'running',
      'tasks_used': 2,
      'children': ['r2'],
      'tree': [
        {
          'key': 'loop',
          'id': 'loop',
          'kind': 'loop',
          'status': 'running',
          'rounds': 2,
          'children': [
            {
              'key': 'loop#1/impl',
              'id': 'impl',
              'kind': 'task',
              'status': 'done',
              'text': '写好了',
              'session': 'flow:r1:impl',
            },
            {
              'key': 'loop#1/ok',
              'id': 'ok',
              'kind': 'gate',
              'status': 'running',
              'options': ['通过', '返工'],
            },
          ],
        },
      ],
    })!;
    expect(run.status, FlowRunStatus.running);
    expect(run.children, ['r2']);
    final gate = run.tree.single.find((n) => n.awaitsAnswer)!;
    expect(gate.options, ['通过', '返工']);
    expect(
        run.tree.single.find((n) => n.id == 'impl')!.session, 'flow:r1:impl');
    expect(FlowRunView.fromResponse({'success': false}), isNull);
  });

  test('node events update the tree in place and run events flip the status',
      () {
    var run = FlowRunView.fromResponse({
      'success': true,
      'run_id': 'r1',
      'status': 'running',
      'tree': [
        {
          'key': 'a',
          'id': 'a',
          'kind': 'seq',
          'children': [
            {'key': 'a/b', 'id': 'b', 'kind': 'task', 'status': 'pending'},
          ],
        },
      ],
    })!;
    run = run.withNodeStatus('a/b', FlowNodeStatus.done, 1);
    expect(run.tree.single.children.single.status, FlowNodeStatus.done);
    run = run.withRunStatus(FlowRunStatus.succeeded);
    expect(run.status.isFinished, isTrue);
  });

  test('events decode and unknown ones are ignored', () {
    final node = FlowEvent.parse('flow.node.changed',
        {'run_id': 'r', 'node': 'a/b', 'status': 'failed', 'attempt': 2})!;
    expect(node.nodeStatus, FlowNodeStatus.failed);
    expect(node.attempt, 2);
    expect(FlowEvent.parse('flow.node.changed', {'run_id': 'r'}), isNull);
    expect(
        FlowEvent.parse(
                'flow.run.changed', {'run_id': 'r', 'status': 'succeeded'})!
            .runStatus,
        FlowRunStatus.succeeded);
  });

  test('requests pair with their response by request_id and time out to null',
      () async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        // 先来一条别人的回包，再来自己的。
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'flow_gate_resp',
          'request_id': 'someone-else',
          'ok': false,
          'error': 'no',
        }));
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'flow_gate_resp',
          'request_id': frame['request_id'],
          'ok': true,
        }));
        return true;
      },
    );
    final answered = await client.answerGate('p1', 'run', 'a', '通过');
    expect(answered.ok, isTrue);
    expect(sent.single['choice'], '通过');

    final offline = HubFlow(events: bus.stream, send: (_, __) async => false);
    final miss = await offline.cancel('p1', 'run');
    expect(miss.reachable, isFalse);
    expect(miss.ok, isFalse);
    await bus.close();
  });
}

void designModelTests() {
  test('a diff decodes into per-node changes and removed ids', () {
    final diff = FlowDiff.fromResponse({
      'success': true,
      'nodes': [
        {'id': 'a', 'kind': 'task', 'change': 'added'},
        {
          'id': 'b',
          'kind': 'task',
          'change': 'changed',
          'fields': [
            {'field': 'task.prompt', 'from': 'x', 'to': 'y'}
          ],
        },
        {'id': 'c', 'kind': 'task', 'change': 'removed'},
        {'id': 'd', 'kind': 'task', 'change': 'bogus'},
      ],
      'header': [
        {'field': 'limits.max_tasks', 'from': 1, 'to': 2}
      ],
    })!;
    expect(diff.nodes.length, 3);
    expect(diff.of('b')!.fields.single.to, 'y');
    expect(diff.removed.single.id, 'c');
    expect(diff.header.single.field, 'limits.max_tasks');
    expect(FlowDiff.fromResponse({'success': false}), isNull);
  });

  test(
      'the schema gives common + per-kind fields; values come from node.fields',
      () {
    final schema = FlowSchema.fromResponse({
      'success': true,
      'common': [
        {'name': 'desc', 'type': 'string', 'label': '说明'}
      ],
      'kinds': {
        'par': [
          {
            'name': 'par.join',
            'type': 'enum',
            'options': ['all', 'any'],
            'label': '汇合'
          }
        ],
      },
    })!;
    expect(schema.fieldsFor('par').map((f) => f.name), ['desc', 'par.join']);
    expect(schema.fieldsFor('par').last.options, ['all', 'any']);
    expect(schema.fieldsFor('unknown').length, 1);
    expect(
        flowFieldValue({
          'task': {'prompt': 'hi'}
        }, 'task.prompt'),
        'hi');
    expect(flowFieldValue({'task': {}}, 'task.model'), isNull);
  });

  test('rehearsal progress lights leaves in dispatch order, containers sum up',
      () {
    final run = FlowRehearsal.fromResponse({
      'success': true,
      'status': 'succeeded',
      'steps': [
        {'key': 'p/a', 'attempt': 1},
        {'key': 'p/b', 'attempt': 1},
      ],
      'tree': [
        {
          'key': 'p',
          'id': 'p',
          'kind': 'par',
          'children': [
            {'key': 'p/a', 'id': 'a', 'kind': 'task'},
            {'key': 'p/b', 'id': 'b', 'kind': 'task'},
          ],
        },
      ],
    })!;
    expect(run.steps, ['p/a', 'p/b']);
    final mid = run.tree.single.withProgress({'p/a'}, 'p/b');
    expect(mid.status, FlowNodeStatus.running);
    expect(mid.children.map((c) => c.status),
        [FlowNodeStatus.done, FlowNodeStatus.running]);
    final all = run.tree.single.withProgress({'p/a', 'p/b'}, null);
    expect(all.status, FlowNodeStatus.done);
    final none = run.tree.single.withProgress({}, null);
    expect(none.status, FlowNodeStatus.pending);
  });

  test('the parent of a node is found for insert-after', () {
    final tree = [
      const FlowNode(key: 'p', id: 'p', kind: 'seq', children: [
        FlowNode(key: 'p/a', id: 'a', kind: 'task'),
        FlowNode(key: 'p/b', id: 'b', kind: 'task'),
      ]),
    ];
    final hit = flowLocate(tree, 'b')!;
    expect(hit.parent!.id, 'p');
    expect(hit.index, 1);
    expect(flowLocate(tree, 'p')!.parent, isNull);
    expect(flowLocate(tree, 'zz'), isNull);
  });

  test('design frames carry the wire fields', () {
    expect(
        HubFlow.diffFrame(
            name: 'dev', scope: 'lib', toRevision: 2, requestId: 'r'),
        {
          'type': 'flow_diff_req',
          'request_id': 'r',
          'scope': 'lib',
          'name': 'dev',
          'to_revision': 2,
        });
    expect(
        HubFlow.editFrame(
            'y',
            [
              {'op': 'delete', 'node_id': 'a'}
            ],
            requestId: 'r'),
        {
          'type': 'flow_edit_req',
          'request_id': 'r',
          'yaml': 'y',
          'ops': [
            {'op': 'delete', 'node_id': 'a'}
          ],
        });
    expect(HubFlow.rehearseFrame('y', requestId: 'r')['type'],
        'flow_rehearse_req');
    expect(HubFlow.schemaFrame()['type'], 'flow_schema_req');
  });
}
