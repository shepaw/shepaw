import 'package:uuid/uuid.dart';

import 'event_bus_store.dart';
import 'event_delivery.dart';
import 'event_envelope.dart';
import 'event_inbox_store.dart';
import 'event_namespace_registry.dart';
import 'event_pattern.dart';
import 'event_router.dart';
import 'event_scope.dart';
import 'event_subscription.dart';
import 'event_type_definition.dart';
import 'perception_scheduler.dart';
import 'wait_lease.dart';

export 'event_envelope.dart';
export 'event_scope.dart';
export 'event_delivery.dart';
export 'event_type_definition.dart';
export 'event_subscription.dart';
export 'event_pattern.dart';
export 'wait_lease.dart';

/// Result of [EventBus.emit].
class EmitResult {
  final String id;
  final int seq;
  final String? correlationId;
  final bool deduplicated;
  final String? originalId;

  const EmitResult({
    required this.id,
    required this.seq,
    this.correlationId,
    this.deduplicated = false,
    this.originalId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        if (correlationId != null) 'correlation_id': correlationId,
        if (deduplicated) 'deduplicated': true,
        if (originalId != null) 'original_id': originalId,
      };
}

/// Global event bus (Service + in-memory store for P0).
class EventBus {
  EventBus._({
    required this.busStore,
    required this.inboxStore,
    required this.registry,
    required this.perceptionScheduler,
    required this.router,
  });

  factory EventBus({
    EventBusStore? busStore,
    EventInboxStore? inboxStore,
    EventNamespaceRegistry? registry,
    PerceptionScheduler? perceptionScheduler,
  }) {
    final store = busStore ?? EventBusStore();
    final inbox = inboxStore ?? EventInboxStore();
    final scheduler = perceptionScheduler ?? PerceptionScheduler();
    return EventBus._(
      busStore: store,
      inboxStore: inbox,
      registry: registry ?? EventNamespaceRegistry.instance,
      perceptionScheduler: scheduler,
      router: EventRouter(
        busStore: store,
        inboxStore: inbox,
        perceptionScheduler: scheduler,
      ),
    );
  }

  static EventBus? _instance;

  static EventBus get instance {
    _instance ??= EventBus();
    return _instance!;
  }

  static void configure(EventBus bus) {
    _instance = bus;
  }

  static void resetForTesting() {
    _instance = null;
  }

  final EventBusStore busStore;
  final EventInboxStore inboxStore;
  final EventNamespaceRegistry registry;
  final PerceptionScheduler perceptionScheduler;
  final EventRouter router;

  final List<WaitLease> _leases = [];
  final List<EventSubscription> _subscriptions = [];
  final _uuid = const Uuid();

  int get currentSeq => busStore.currentSeq;

  EventSubscription addSubscription({
    String? subscriptionId,
    required String agentId,
    required List<EventPattern> patterns,
    EventDelivery delivery = EventDelivery.pollOnly,
    String? channelBinding,
    bool persistent = false,
    DateTime? expiresAt,
    bool enabled = true,
    int? createdSeq,
  }) {
    final sub = EventSubscription(
      id: subscriptionId ?? 'sub_${_uuid.v4()}',
      agentId: agentId,
      patterns: patterns,
      delivery: delivery,
      channelBinding: channelBinding,
      persistent: persistent,
      expiresAt: expiresAt,
      enabled: enabled,
      createdSeq: createdSeq ?? busStore.currentSeq,
    );
    _subscriptions.add(sub);
    return sub;
  }

  List<EventSubscription> subscriptionsFor(String agentId) =>
      _subscriptions.where((s) => s.agentId == agentId).toList();

  List<EventSubscription> get allSubscriptions =>
      List.unmodifiable(_subscriptions);

  bool removeSubscription(String subscriptionId) {
    final before = _subscriptions.length;
    _subscriptions.removeWhere((s) => s.id == subscriptionId);
    return _subscriptions.length < before;
  }

  EventSubscription? findSubscription(String subscriptionId) {
    for (final s in _subscriptions) {
      if (s.id == subscriptionId) return s;
    }
    return null;
  }

  WaitLease openWaitLease({
    required String agentId,
    String? correlationId,
    required List<String> typePatterns,
    EventScope? scopeFilter,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (correlationId != null) {
      final conflict = _leases.any(
        (l) =>
            !l.completed &&
            !l.cancelled &&
            l.agentId == agentId &&
            l.correlationId == correlationId,
      );
      if (conflict) {
        throw CorrelationAlreadyWaitedException(correlationId);
      }
    }

    _pruneLeases();

    final lease = WaitLease(
      leaseId: 'wl_${_uuid.v4()}',
      agentId: agentId,
      correlationId: correlationId,
      typePatterns: typePatterns,
      scopeFilter: scopeFilter,
      seqAtOpen: busStore.currentSeq,
      expiresAt: DateTime.now().add(timeout),
    );
    _leases.add(lease);
    return lease;
  }

  Future<EventEnvelope> waitOnLease(WaitLease lease) async {
    try {
      return await lease.completer.future.timeout(
        lease.expiresAt.difference(DateTime.now()),
        onTimeout: () {
          lease.timeout();
          throw WaitTimeoutException(lease.leaseId);
        },
      );
    } finally {
      _leases.remove(lease);
    }
  }

  void cancelWaitLease(String leaseId) {
    for (final lease in _leases) {
      if (lease.leaseId == leaseId) {
        lease.cancel();
        _leases.remove(lease);
        return;
      }
    }
  }

  /// Emit from a system provider (`source` derived as `system:<domain>`).
  EmitResult emitSystem({
    required String systemDomain,
    required String type,
    required Map<String, dynamic> payload,
    EventScope scope = const EventScope(),
    String? correlationId,
    String? causationId,
  }) {
    // 域白名单：`system:<domain>` 只能发自己域下的 type，避免任意调用方
    // 冒用 `system:peer` 等受信任来源（emit 的 source 由调用方法推导，不可传入）。
    if (!type.startsWith('$systemDomain.')) {
      throw ArgumentError(
        'System domain "$systemDomain" may not emit $type',
      );
    }
    return _emit(
      source: 'system:$systemDomain',
      type: type,
      payload: payload,
      scope: scope,
      correlationId: correlationId,
      causationId: causationId,
    );
  }

  /// Emit from an agent CLI (`events emit`).
  EmitResult emitAgent({
    required String agentId,
    required String type,
    required Map<String, dynamic> payload,
    EventScope scope = const EventScope(),
    String? correlationId,
    String? causationId,
  }) {
    if (!type.startsWith('agent.$agentId.')) {
      throw ArgumentError(
        'Agents may only emit agent.$agentId.* (got $type)',
      );
    }
    _ensureAgentEventTypeRegistered(type);
    return _emit(
      source: 'agent:$agentId',
      type: type,
      payload: payload,
      scope: scope,
      correlationId: correlationId,
      causationId: causationId,
    );
  }

  EmitResult _emit({
    required String source,
    required String type,
    required Map<String, dynamic> payload,
    required EventScope scope,
    String? correlationId,
    String? causationId,
  }) {
    final typeDef = registry.get(type);
    if (typeDef == null) {
      throw ArgumentError('Unknown event type: $type');
    }

    _validateRequired(typeDef, correlationId: correlationId, scope: scope);

    final dedupeKey = computeDedupeKey(
      typeDef,
      type: type,
      correlationId: correlationId,
      payload: payload,
      scopeValues: {
        'device_id': scope.deviceId,
        'owner_id': scope.ownerId,
        'peer_id': scope.peerId,
      },
    );

    var deduplicated = false;
    String? originalId;
    EventEnvelope envelope;

    if (dedupeKey != null) {
      originalId = busStore.recentDedupeOriginalId(dedupeKey);
      if (originalId != null) {
        deduplicated = true;
        final existing = busStore.findById(originalId);
        if (existing != null) {
          envelope = existing;
        } else {
          envelope = _buildEnvelope(
            source: source,
            type: type,
            payload: payload,
            scope: scope,
            correlationId: correlationId,
            causationId: causationId,
            dedupeKey: dedupeKey,
          );
        }
      } else {
        envelope = _buildEnvelope(
          source: source,
          type: type,
          payload: payload,
          scope: scope,
          correlationId: correlationId,
          causationId: causationId,
          dedupeKey: dedupeKey,
        );
        busStore.recordDedupe(dedupeKey, envelope.id);
      }
    } else {
      envelope = _buildEnvelope(
        source: source,
        type: type,
        payload: payload,
        scope: scope,
        correlationId: correlationId,
        causationId: causationId,
        dedupeKey: dedupeKey,
      );
    }

    if (!deduplicated) {
      busStore.append(envelope);
    }

    router.dispatch(
      envelope,
      activeLeases: _activeLeases(),
      subscriptions: _subscriptions,
    );

    return EmitResult(
      id: envelope.id,
      seq: envelope.seq,
      correlationId: correlationId,
      deduplicated: deduplicated,
      originalId: originalId,
    );
  }

  EventEnvelope _buildEnvelope({
    required String source,
    required String type,
    required Map<String, dynamic> payload,
    required EventScope scope,
    String? correlationId,
    String? causationId,
    String? dedupeKey,
  }) {
    return EventEnvelope(
      id: 'evt_${_uuid.v4()}',
      type: type,
      source: source,
      correlationId: correlationId,
      causationId: causationId,
      seq: busStore.nextSeq(),
      at: DateTime.now(),
      payload: payload,
      scope: scope,
      dedupeKey: dedupeKey,
    );
  }

  void _validateRequired(
    EventTypeDefinition typeDef, {
    String? correlationId,
    required EventScope scope,
  }) {
    for (final key in typeDef.requiredEnvelopeKeys) {
      if (key == 'correlationId' && (correlationId == null || correlationId.isEmpty)) {
        throw ArgumentError('Missing required envelope key: correlationId');
      }
    }
    for (final key in typeDef.requiredScopeKeys) {
      final value = _scopeValue(scope, key);
      if (value == null || value.isEmpty) {
        throw ArgumentError('Missing required scope key: $key');
      }
    }
  }

  String? _scopeValue(EventScope scope, String key) {
    switch (key) {
      case 'channelId':
        return scope.channelId;
      case 'agentId':
        return scope.agentId;
      case 'peerId':
        return scope.peerId;
      case 'deviceId':
        return scope.deviceId;
      case 'ownerId':
        return scope.ownerId;
      default:
        return null;
    }
  }

  Iterable<WaitLease> _activeLeases() =>
      _leases.where((l) => !l.completed && !l.cancelled && !l.isExpired);

  void _pruneLeases() {
    _leases.removeWhere((l) => l.completed || l.cancelled || l.isExpired);
  }

  List<InboxEntry> inboxFor(
    String agentId, {
    int cursor = 0,
    int limit = 20,
    bool unreadOnly = false,
    String? correlationId,
    String? typePattern,
  }) {
    return inboxStore.inboxFor(
      agentId,
      cursor: cursor,
      limit: limit,
      unreadOnly: unreadOnly,
      correlationId: correlationId,
      typePattern: typePattern,
    );
  }

  /// passive 事件的「下一回合上下文」文本块；无未读内容返回 null。
  ///
  /// 只取 delivery=passive 且未 ack 的条目（active 已单独唤醒、poll_only 需
  /// 显式轮询），最多 [maxEvents] 条，按 seq 升序。注入方见
  /// `AgentPromptBuilder.eventContext`。
  String? buildPassiveContext(String agentId, {int maxEvents = 5}) {
    final entries = inboxStore.unreadByDelivery(
      agentId,
      EventDelivery.passive.wireValue,
      limit: maxEvents,
    );
    if (entries.isEmpty) return null;

    final buffer = StringBuffer()
      ..writeln('【系统事件 · 近期未读】')
      ..writeln(
          '以下事件已投递到你的事件收件箱，尚未确认；可用 `shepaw events ack` 确认：');
    for (final entry in entries) {
      final summary = entry.event.payload['summary'];
      final text = summary is String && summary.isNotEmpty
          ? summary
          : entry.event.type;
      final correlation = entry.event.correlationId;
      buffer.write('- $text（${entry.event.type}');
      if (correlation != null && correlation.isNotEmpty) {
        buffer.write('，correlation=$correlation');
      }
      buffer.writeln('）');
    }
    return buffer.toString();
  }

  int ackInbox(
    String agentId, {
    String? eventId,
    String? correlationId,
  }) {
    return inboxStore.ack(
      agentId,
      eventId: eventId,
      correlationId: correlationId,
    );
  }

  void _ensureAgentEventTypeRegistered(String type) {
    if (registry.get(type) != null) return;
    registry.register(EventTypeDefinition(
      id: type,
      description: 'Agent custom event',
      defaultDelivery: EventDelivery.pollOnly,
    ));
  }

  void clearState() {
    busStore.reset();
    inboxStore.reset();
    perceptionScheduler.reset();
    _leases.clear();
    _subscriptions.clear();
  }
}

String generateCorrelationId() => 'cid_${const Uuid().v4()}';
