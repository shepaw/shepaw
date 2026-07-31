import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../models/inference_log_entry.dart';
import '../../services/trace_service.dart';
import '../models/peer_message.dart';

/// Structured traces for human peer-to-peer chat delivery and Noise connections.
///
/// Channel id convention: `peer_device__{peerId}` — used by [ChannelTraceScreen]
/// on device chat pages.
class PeerDeliveryTraceService {
  PeerDeliveryTraceService._();
  static final PeerDeliveryTraceService instance = PeerDeliveryTraceService._();

  static const _uuid = Uuid();

  /// Synthetic channel id for querying traces in the peer device chat UI.
  static String channelIdForPeer(String peerId) => 'peer_device__$peerId';

  final Map<String, String> _messageTraceIds = {};
  final Map<String, String> _connectionTraceIds = {};

  // ---------------------------------------------------------------------------
  // Message delivery
  // ---------------------------------------------------------------------------

  /// Start tracing an outbound human peer message (before send / queue).
  void beginOutboundMessage({
    required String peerId,
    required PeerMessage message,
  }) {
    final preview = message.content.length > 200
        ? '${message.content.substring(0, 200)}...'
        : message.content;
    final traceId = TraceService.instance.beginTrace(
      sessionId: _uuid.v4(),
      agentId: peerId,
      agentName: 'peer_device',
      channelId: channelIdForPeer(peerId),
      executionMode: 'peer_human_dm',
      traceRole: 'peer_message_delivery',
      userMessage: preview,
      systemPrompt: json.encode({
        'peer_id': peerId,
        'message_id': message.id,
        'sender_id': message.senderId,
        'direction': 'outbound',
        'message_type': message.type.name,
      }),
    );
    _messageTraceIds[message.id] = traceId;
    _addDeliverySpan(traceId, 'pending', metadata: {
      'message_id': message.id,
      'delivery_status': 'pending',
    });
  }

  /// Record local send outcome: `sent`, `queued_offline`, or `send_failed`.
  void recordOutboundSend(
    String messageId, {
    required String status,
    String? error,
  }) {
    final traceId = _messageTraceIds[messageId];
    if (traceId == null) return;
    _addDeliverySpan(
      traceId,
      status,
      metadata: {'message_id': messageId, 'delivery_status': status},
      error: error,
    );
    if (status == 'send_failed') {
      _finishMessageTrace(messageId, InferenceStatus.error, error: error);
    }
  }

  /// Record inbound delivery ack (`delivered` / `read`) or local `sent`.
  void recordDeliveryAck(String messageId, String status) {
    final traceId = _messageTraceIds[messageId];
    if (traceId == null) return;
    _addDeliverySpan(
      traceId,
      status,
      metadata: {'message_id': messageId, 'delivery_status': status},
    );
    if (status == 'delivered' || status == 'read') {
      _finishMessageTrace(messageId, InferenceStatus.completed);
    }
  }

  /// Trace an inbound human peer message and the auto delivered-ack we send back.
  void traceInboundMessage({
    required String peerId,
    required PeerMessage message,
    required bool ackSent,
    String? ackError,
  }) {
    final preview = message.content.length > 200
        ? '${message.content.substring(0, 200)}...'
        : message.content;
    final traceId = TraceService.instance.beginTrace(
      sessionId: _uuid.v4(),
      agentId: peerId,
      agentName: 'peer_device',
      channelId: channelIdForPeer(peerId),
      executionMode: 'peer_human_dm',
      traceRole: 'peer_message_delivery',
      userMessage: preview,
      systemPrompt: json.encode({
        'peer_id': peerId,
        'message_id': message.id,
        'sender_id': message.senderId,
        'direction': 'inbound',
        'message_type': message.type.name,
      }),
    );
    _addDeliverySpan(traceId, 'received', metadata: {
      'message_id': message.id,
      'delivery_status': 'received',
    });
    _addDeliverySpan(
      traceId,
      ackSent ? 'ack_delivered_sent' : 'ack_delivered_failed',
      metadata: {
        'message_id': message.id,
        'delivery_status': ackSent ? 'delivered' : 'ack_failed',
      },
      error: ackError,
    );
    TraceService.instance.endTrace(
      traceId,
      ackSent ? InferenceStatus.completed : InferenceStatus.error,
      error: ackError,
    );
  }

  void _finishMessageTrace(
    String messageId,
    InferenceStatus status, {
    String? error,
  }) {
    final traceId = _messageTraceIds.remove(messageId);
    if (traceId == null) return;
    TraceService.instance.endTrace(traceId, status, error: error);
  }

  void _addDeliverySpan(
    String traceId,
    String name, {
    Map<String, dynamic>? metadata,
    String? error,
  }) {
    final spanId = TraceService.instance.addSpan(
      traceId: traceId,
      spanType: 'delivery',
      name: name,
      metadata: metadata,
    );
    TraceService.instance.endSpan(
      spanId,
      status: error != null ? 'error' : 'completed',
      error: error,
      outputData: metadata,
    );
  }

  // ---------------------------------------------------------------------------
  // Connection / Noise handshake
  // ---------------------------------------------------------------------------

  /// Begin tracing a connect or inbound-accept attempt for [peerId].
  void beginConnectionAttempt({
    required String peerId,
    required String deviceName,
    required String role,
    String? trigger,
  }) {
    _finishConnectionTrace(peerId, InferenceStatus.cancelled);

    final traceId = TraceService.instance.beginTrace(
      sessionId: _uuid.v4(),
      agentId: peerId,
      agentName: deviceName,
      channelId: channelIdForPeer(peerId),
      executionMode: 'peer_noise_handshake',
      traceRole: 'peer_connection',
      userMessage: 'Connect $deviceName',
      systemPrompt: json.encode({
        'peer_id': peerId,
        'role': role,
        if (trigger != null) 'trigger': trigger,
      }),
    );
    _connectionTraceIds[peerId] = traceId;
    _addConnectionSpan(traceId, 'connect_start', metadata: {
      'role': role,
      if (trigger != null) 'trigger': trigger,
    });
  }

  /// Record a transport attempt during initiator connect.
  void recordTransportAttempt({
    required String peerId,
    required String transport,
    required bool success,
    String? endpoint,
    String? error,
  }) {
    final traceId = _connectionTraceIds[peerId];
    if (traceId == null) return;
    _addConnectionSpan(
      traceId,
      success ? 'transport_ok' : 'transport_failed',
      metadata: {
        'transport': transport,
        if (endpoint != null) 'endpoint': endpoint,
        'success': success,
      },
      error: error,
    );
  }

  /// Record Noise handshake completion (initiator or responder).
  void recordHandshakeSuccess({
    required String peerId,
    required String role,
    required String transport,
    Map<String, dynamic>? endpoints,
  }) {
    final traceId = _connectionTraceIds[peerId];
    if (traceId == null) return;
    _addConnectionSpan(traceId, 'noise_handshake', metadata: {
      'role': role,
      'transport': transport,
      'handshake': 'completed',
      if (endpoints != null) ...endpoints,
    });
    _finishConnectionTrace(peerId, InferenceStatus.completed);
  }

  /// Record handshake / connect failure.
  void recordConnectionFailure({
    required String peerId,
    required String stage,
    String? error,
  }) {
    final traceId = _connectionTraceIds[peerId];
    if (traceId == null) return;
    _addConnectionSpan(
      traceId,
      stage,
      metadata: {'stage': stage},
      error: error,
    );
    _finishConnectionTrace(peerId, InferenceStatus.error, error: error);
  }

  void _finishConnectionTrace(
    String peerId,
    InferenceStatus status, {
    String? error,
  }) {
    final traceId = _connectionTraceIds.remove(peerId);
    if (traceId == null) return;
    TraceService.instance.endTrace(traceId, status, error: error);
  }

  void _addConnectionSpan(
    String traceId,
    String name, {
    Map<String, dynamic>? metadata,
    String? error,
  }) {
    final spanId = TraceService.instance.addSpan(
      traceId: traceId,
      spanType: 'connection',
      name: name,
      metadata: metadata,
    );
    TraceService.instance.endSpan(
      spanId,
      status: error != null ? 'error' : 'completed',
      error: error,
      outputData: metadata,
    );
  }
}
