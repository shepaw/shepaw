import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_templates.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  test('画廊优先用主机 flow_list 的 description，并标出用户改过的模板', () async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        bus.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'flow_list_resp',
            'success': true,
            'flows': [
              {
                'name': 'builtin-review-loop',
                'latest': 2,
                'description': '库里改过的说明',
                'updated_by': 'user',
              },
              {
                'name': 'builtin-stage-gate',
                'latest': 1,
                'description': '两道关卡',
                'updated_by': 'hub',
              },
            ],
            'request_id': frame['request_id'],
          },
        ));
        return true;
      },
    );

    final entries = await FlowTemplateCatalog.load(client, 'p1');
    final review = entries.firstWhere((e) => e.id == 'builtin-review-loop');
    expect(review.blurb(true), '库里改过的说明');
    expect(review.modified, isTrue);
    final gate = entries.firstWhere((e) => e.id == 'builtin-stage-gate');
    expect(gate.blurb(true), '两道关卡');
    expect(gate.modified, isFalse);
    // 库里没有的模板回退客户端文案，且不误标「已修改」。
    final lead = entries.firstWhere((e) => e.id == 'builtin-lead');
    expect(lead.blurb(true), '交给领队自己拆成若干步再执行');
    expect(lead.modified, isFalse);
  });

  test('主机没应答时仍给完整名单（回退内置文案）', () async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    final client = HubFlow(
      events: bus.stream,
      send: (_, __) async => false,
    );
    final entries = await FlowTemplateCatalog.load(client, 'p1');
    expect(entries.length, FlowTemplateCatalog.builtins.length);
    expect(
      entries.first.blurb(true),
      FlowTemplateCatalog.builtins.first.blurbZh,
    );
  });
}
