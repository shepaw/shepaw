import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_host_caps.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  test('startFrame 带 origin：线上字段原样发出，旧字段一个不少', () {
    final origin = {'kind': 'slip', 'slip_id': 's1'};
    expect(
      HubFlow.startFrame(name: 't', inputs: {'a': 1}, origin: origin),
      {
        'type': 'flow_run_start_req',
        'name': 't',
        'inputs': {'a': 1},
        'origin': origin,
      },
    );
    expect(
      HubFlow.startFrame(
        name: 't',
        scope: 'lib',
        revision: 2,
        inputs: {'a': 1},
        bindings: {'coder': 'agent-1'},
        groupId: 'g1',
        sessionId: 'sess1',
        taskId: 'task1',
        requestId: 'req1',
        origin: {
          'kind': 'slip',
          'slip_id': 's1',
          'device_id': 'd1',
        },
      ),
      {
        'type': 'flow_run_start_req',
        'request_id': 'req1',
        'scope': 'lib',
        'name': 't',
        'revision': 2,
        'inputs': {'a': 1},
        'bindings': {'coder': 'agent-1'},
        'group_id': 'g1',
        'session_id': 'sess1',
        'task_id': 'task1',
        'origin': {
          'kind': 'slip',
          'slip_id': 's1',
          'device_id': 'd1',
        },
      },
    );
  });

  test('startFrame 不给 origin 时不发这个键（旧主机兼容）', () {
    final frame = HubFlow.startFrame(name: 't', inputs: {'a': 1});
    expect(frame.containsKey('origin'), isFalse);
    expect(frame, {
      'type': 'flow_run_start_req',
      'name': 't',
      'inputs': {'a': 1},
    });
  });

  test('start 把 origin 转发到帧里，并保留响应的 origin_ack', () async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'flow_run_start_resp',
          'request_id': frame['request_id'],
          'success': true,
          'run_id': 'r1',
          'origin_ack': true,
        }));
        return true;
      },
    );
    final call = await client.start(
      'p1',
      name: 't',
      origin: {'kind': 'slip', 'slip_id': 's1'},
    );
    expect(sent.single['origin'], {'kind': 'slip', 'slip_id': 's1'});
    expect(call.runId, 'r1');
    expect(call.originAck, isTrue);
    await bus.close();
  });

  test('FlowCall 保留 origin_ack，只有真正的 true 才算收到', () {
    expect(
      FlowCall.fromResponse({
        'type': 'flow_run_start_resp',
        'success': true,
        'run_id': 'r1',
        'origin_ack': true,
      }).originAck,
      isTrue,
    );
    expect(
        FlowCall.fromResponse({
          'success': true,
          'run_id': 'r1',
        }).originAck,
        isFalse);
    expect(
        FlowCall.fromResponse({
          'success': true,
          'origin_ack': false,
        }).originAck,
        isFalse);
    expect(
        FlowCall.fromResponse({
          'success': true,
          'origin_ack': 'true',
        }).originAck,
        isFalse);
    expect(FlowCall.fromResponse(null).originAck, isFalse);
    // 响应帧里的其它键也不许被过滤掉。
    expect(
        FlowCall.fromResponse({
          'success': true,
          'origin_ack': true,
          'extra': 7,
        }).data['extra'],
        7);
  });

  test('FlowRunOrigin.tryParse 容错、toJson 往返、isSlip 判定', () {
    const originJson = {
      'kind': 'slip',
      'slip_id': 's1',
      'device_id': 'd1',
    };
    final origin = FlowRunOrigin.tryParse(originJson)!;
    expect(origin.kind, 'slip');
    expect(origin.slipId, 's1');
    expect(origin.deviceId, 'd1');
    expect(origin.isSlip, isTrue);
    expect(origin.toJson(), originJson);
    expect(FlowRunOrigin.tryParse(origin.toJson())!.toJson(), originJson);

    // 非 Map 一律 null；Map 里字段类型不对也不许抛，退化成空串。
    expect(FlowRunOrigin.tryParse(null), isNull);
    expect(FlowRunOrigin.tryParse('slip'), isNull);
    expect(FlowRunOrigin.tryParse(42), isNull);
    expect(FlowRunOrigin.tryParse(['slip']), isNull);
    final wrongTypes = FlowRunOrigin.tryParse({
      'kind': 7,
      'slip_id': <int>[1],
      'device_id': null,
    })!;
    expect(wrongTypes.kind, '');
    expect(wrongTypes.slipId, '');
    expect(wrongTypes.deviceId, '');
    expect(wrongTypes.toJson(), isEmpty);
    expect(wrongTypes.isSlip, isFalse);
    expect(
        FlowRunOrigin.tryParse({
          'kind': 'slip',
          'slip_id': 's1',
          'device_id': 7,
        })!
            .deviceId,
        '');

    // factory 不能返回 null，坏输入给空对象；空字段不发。
    expect(FlowRunOrigin.fromJson('bad').toJson(), isEmpty);
    expect(FlowRunOrigin.fromJson(null).isSlip, isFalse);
    expect(FlowRunOrigin.fromJson(originJson).slipId, 's1');
    expect(const FlowRunOrigin().toJson(), isEmpty);
    expect(const FlowRunOrigin(kind: 'slip', slipId: 's1').toJson(), {
      'kind': 'slip',
      'slip_id': 's1',
    });
    expect(const FlowRunOrigin(kind: 'agent', slipId: 's1').isSlip, isFalse);
    expect(const FlowRunOrigin(kind: 'slip').isSlip, isFalse);
  });

  test('运行列表 / 详情解析 origin，旧响应为 null', () {
    final originJson = {
      'kind': 'slip',
      'slip_id': 's1',
      'device_id': 'd1',
    };
    final runs = FlowRunSummary.listFromResponse({
      'success': true,
      'runs': [
        {
          'run_id': 'r1',
          'flow': 't',
          'status': 'running',
          'origin': originJson,
        },
        {'run_id': 'r2', 'flow': 't', 'status': 'succeeded'},
      ],
    });
    expect(runs.length, 2);
    expect(runs[0].origin?.slipId, 's1');
    expect(runs[0].origin?.deviceId, 'd1');
    expect(runs[0].origin?.isSlip, isTrue);
    expect(runs[1].origin, isNull);
    expect(
        FlowRunSummary.listFromResponse({
          'success': true,
          'runs': [
            {
              'run_id': 'r3',
              'flow': 't',
              'status': 'running',
              'origin': 'oops',
            },
          ],
        }).single.origin,
        isNull);

    final view = FlowRunView.fromResponse({
      'success': true,
      'run_id': 'r1',
      'status': 'running',
      'tree': [
        {'key': 'a', 'id': 'a', 'kind': 'task', 'status': 'pending'},
      ],
      'origin': originJson,
    })!;
    expect(view.origin?.slipId, 's1');
    expect(view.origin?.isSlip, isTrue);
    // 本地状态更新不能把 origin 丢掉，否则运行页「来自玉简」入口会闪没。
    expect(
        view.withNodeStatus('a', FlowNodeStatus.done, 1).origin?.slipId, 's1');
    expect(view.withRunStatus(FlowRunStatus.succeeded).origin?.slipId, 's1');

    final legacy = FlowRunView.fromResponse({
      'success': true,
      'run_id': 'r2',
      'status': 'running',
      'tree': [],
    })!;
    expect(legacy.origin, isNull);
  });

  test('FlowSchema.caps / FlowHostCaps.canWriteBackToSlip', () {
    final modern = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
      'caps': ['flow_origin'],
    })!;
    expect(modern.hasCap('flow_origin'), isTrue);
    expect(modern.hasCap('other'), isFalse);
    expect(FlowHostCaps.of(modern, const []).flowOrigin, isTrue);
    expect(FlowHostCaps.of(modern, const []).canWriteBackToSlip, isTrue);

    final legacy = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
    })!;
    expect(legacy.caps, isEmpty);
    expect(legacy.hasCap('flow_origin'), isFalse);
    expect(FlowHostCaps.of(legacy, const []).canWriteBackToSlip, isFalse);
    expect(FlowHostCaps.of(null, const []).canWriteBackToSlip, isFalse);
    expect(FlowHostCaps.none.canWriteBackToSlip, isFalse);

    // caps 类型不对不能让整帧解析崩；列表里什么类型都转成字符串。
    expect(
        FlowSchema.fromResponse({
          'success': true,
          'caps': 'flow_origin',
        })!
            .caps,
        isEmpty);
    final mixed = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
      'caps': [7, 'flow_origin', null],
    })!;
    expect(mixed.hasCap('flow_origin'), isTrue);
    expect(mixed.hasCap('7'), isTrue);

    // 旧调用不传新参数也能编译。
    expect(
        const FlowSchema(common: [], kinds: {}).hasCap('flow_origin'), isFalse);
    expect(
        const FlowHostCaps(
          canEdit: true,
          canEditHeader: true,
          canRetype: true,
          canMove: true,
          branchesLabelled: true,
        ).canWriteBackToSlip,
        isFalse);
  });
}
