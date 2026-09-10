import '../../peer/services/peer_pairing_service.dart';
import '../local_user_identity.dart';
import '../she_service.dart';
import 'event_bus.dart';
import 'event_delivery.dart';
import 'event_namespace_registry.dart';
import 'event_pattern.dart';
import 'event_scope.dart';
import 'event_type_definition.dart';

/// Built-in provider: peer pairing lifecycle → EventBus.
class PeerEventProvider {
  PeerEventProvider._();

  static void registerTypes(EventNamespaceRegistry registry) {
    registry.registerAll([
      const EventTypeDefinition(
        id: 'peer.pairing.inbound',
        description: 'Responder received a valid pairing request',
        defaultDelivery: EventDelivery.active,
        requiredEnvelopeKeys: ['correlationId'],
        requiredScopeKeys: ['ownerId'],
        dedupeKeyTemplate: '{type}:{correlation_id}:{payload.fingerprint}',
      ),
      const EventTypeDefinition(
        id: 'peer.pairing.completed',
        description: 'Pairing succeeded (initiator or responder)',
        defaultDelivery: EventDelivery.passive,
        requiredEnvelopeKeys: ['correlationId'],
        requiredScopeKeys: ['peerId'],
      ),
      const EventTypeDefinition(
        id: 'peer.pairing.rejected',
        description: 'Pairing rejected or invalid code',
        defaultDelivery: EventDelivery.passive,
        requiredEnvelopeKeys: ['correlationId'],
      ),
      const EventTypeDefinition(
        id: 'peer.connection.changed',
        description: 'Paired device connection state changed',
        defaultDelivery: EventDelivery.pollOnly,
        requiredScopeKeys: ['peerId'],
      ),
    ]);
  }

  static void seedSheInboundSubscription(EventBus bus) {
    bus.addSubscription(
      agentId: SheService.sheId,
      patterns: const [
        EventPattern(typeGlob: 'peer.pairing.inbound'),
      ],
      delivery: EventDelivery.active,
      persistent: true,
    );
  }

  static void emitInbound({
    required IncomingPairingRequest request,
    required String correlationId,
  }) {
    EventBus.instance.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.inbound',
      payload: {
        'summary': '设备 ${request.deviceName} 请求配对',
        ...request.toJson(),
      },
      scope: EventScope(ownerId: LocalUserIdentity.id),
      correlationId: correlationId,
    );
  }

  static void emitCompleted({
    required String correlationId,
    required String peerId,
    required String deviceName,
    required String role,
    String? trustLevel,
  }) {
    EventBus.instance.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.completed',
      payload: {
        'summary': '已与 $deviceName 配对成功',
        'peer_id': peerId,
        'device_name': deviceName,
        'role': role,
        if (trustLevel != null) 'trust_level': trustLevel,
      },
      scope: EventScope(ownerId: LocalUserIdentity.id, peerId: peerId),
      correlationId: correlationId,
    );
  }

  static void emitRejected({
    required String correlationId,
    required String reason,
  }) {
    EventBus.instance.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.rejected',
      payload: {
        'summary': '配对被拒绝',
        'reason': reason,
      },
      scope: EventScope(ownerId: LocalUserIdentity.id),
      correlationId: correlationId,
    );
  }
}
