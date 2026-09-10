import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_perception_service.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/setup_event_bus.dart';
import 'package:shepaw/services/she_service.dart';

/// Responder 侧事件链（不含真实网络）：She seed 订阅 → active 唤醒；
/// 若**先**开 wait lease 再 emit completed，RPC 可完成（非 Initiator `pair` 路径）。
///
/// Initiator `peer pair` 是同步 RPC，completed 在 return 前已 emit，**不应**再 wait。
void main() {
  late EventBus bus;
  const cid = 'cid_e2e';

  final turns = <({String agentId, String channelId, List<String> types})>[];

  setUp(() {
    turns.clear();
    bus = EventBus();
    setupEventBus(bus: bus);
    bus.perceptionScheduler.debounce = Duration.zero;
    EventPerceptionService.instance.runNotifyTurn =
        (agentId, channelId, events) async {
      turns.add((
        agentId: agentId,
        channelId: channelId,
        types: events.map((e) => e.type).toList(),
      ));
    };
  });

  tearDown(() {
    EventPerceptionService.instance.runNotifyTurn = null;
  });

  test('inbound 唤醒 She，completed 完成同 correlation 的 wait', () async {
    // She 在 offer 之后开 RPC 等待（机器速度，≤120s）
    final lease = bus.openWaitLease(
      agentId: SheService.sheId,
      correlationId: cid,
      typePatterns: ['peer.pairing.completed'],
    );

    // 对端扫码连入 → 入站事件
    bus.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.inbound',
      payload: {
        'summary': '设备 MacBook-Pro 请求配对',
        'device_name': 'MacBook-Pro',
        'fingerprint': 'fp_e2e',
      },
      scope: const EventScope(ownerId: 'owner_e2e'),
      correlationId: cid,
    );
    await Future<void>.delayed(Duration.zero);

    // seed 订阅（active）应触发一次 notify-only 回合，且仅 She
    expect(turns.length, 1);
    expect(turns.first.agentId, SheService.sheId);
    expect(turns.first.types, ['peer.pairing.inbound']);
    // 事件不带频道 → 交给执行方解析 DM 频道
    expect(turns.first.channelId, isEmpty);
    // 同时进 She inbox（审计）
    expect(bus.inboxFor(SheService.sheId).length, 1);

    // She 调用 peer accept → 同 correlation 的 completed
    bus.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.completed',
      payload: {
        'summary': '已与 MacBook-Pro 配对成功',
        'peer_id': 'peer_e2e',
        'device_name': 'MacBook-Pro',
        'role': 'responder',
      },
      scope: const EventScope(ownerId: 'owner_e2e', peerId: 'peer_e2e'),
      correlationId: cid,
    );

    final event = await lease.completer.future;
    expect(event.correlationId, cid);
    expect(event.type, 'peer.pairing.completed');
  });

  test('不同 correlation 的 completed 不完成本次 wait', () async {
    final lease = bus.openWaitLease(
      agentId: SheService.sheId,
      correlationId: cid,
      typePatterns: ['peer.pairing.completed'],
    );

    bus.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.completed',
      payload: {'summary': 'other', 'peer_id': 'p2', 'role': 'responder'},
      scope: const EventScope(ownerId: 'owner_e2e', peerId: 'p2'),
      correlationId: 'cid_other',
    );
    await Future<void>.delayed(Duration.zero);

    expect(lease.completed, isFalse);
  });
}
