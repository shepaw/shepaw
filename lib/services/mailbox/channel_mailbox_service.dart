/// Channel mailbox REST client (app side): leave messages when agent is busy,
/// fetch sealed replies when entering a chat.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logger_service.dart';

class ChannelMailboxException implements Exception {
  ChannelMailboxException(this.message);
  final String message;
  @override
  String toString() => 'ChannelMailboxException: $message';
}

class MailboxReply {
  MailboxReply({
    required this.id,
    required this.messageId,
    required this.replyTo,
    required this.sessionId,
    required this.ciphertext,
    required this.createdAt,
  });

  final String id;
  final String messageId;
  final String replyTo;
  final String sessionId;
  final String ciphertext;
  final String createdAt;

  factory MailboxReply.fromJson(Map<String, dynamic> j) => MailboxReply(
        id: j['id'] as String,
        messageId: j['message_id'] as String? ?? '',
        replyTo: j['reply_to'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        ciphertext: j['ciphertext'] as String,
        createdAt: j['created_at'] as String? ?? '',
      );
}

class ChannelMailboxService {
  ChannelMailboxService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// True only for Channel Service relay URLs (`/proxy/<id>/…` or `/c/<alias>/…`).
  /// LAN / loopback ACP endpoints (`ws://192.168.x.x:port/acp/ws`) must not
  /// match — otherwise the app would hit a non-existent mailbox API and stall.
  static bool isChannelRelayEndpoint(String endpoint) {
    final trimmed = endpoint.trim();
    if (trimmed.isEmpty) return false;
    try {
      final normalized = trimmed
          .replaceFirst(RegExp(r'^wss://'), 'https://')
          .replaceFirst(RegExp(r'^ws://'), 'http://');
      final path = Uri.parse(normalized).path;
      return path.contains('/proxy/') ||
          path.startsWith('/proxy/') ||
          path.startsWith('/c/');
    } catch (_) {
      return false;
    }
  }

  /// Derive HTTPS channel base from an agent WS/HTTP endpoint.
  /// Returns null for non-relay (LAN) endpoints so mailbox/access stay optional.
  /// e.g. `wss://host/proxy/xxx/acp/ws` → `https://host`
  static String? channelBaseFromEndpoint(String endpoint) {
    if (!isChannelRelayEndpoint(endpoint)) return null;
    final trimmed = endpoint.trim();
    try {
      final normalized = trimmed
          .replaceFirst(RegExp(r'^wss://'), 'https://')
          .replaceFirst(RegExp(r'^ws://'), 'http://');
      final uri = Uri.parse(normalized);
      if (uri.host.isEmpty) return null;
      return uri.origin;
    } catch (_) {
      return null;
    }
  }

  /// Extract ACP agent id from endpoint query (`agentId=`) or return [fallback].
  static String resolveAgentId(String endpoint, {String? fallback}) {
    try {
      final uri = Uri.parse(endpoint);
      final q = uri.queryParameters['agentId'];
      if (q != null && q.isNotEmpty) return q;
    } catch (_) {}
    return fallback ?? '';
  }

  Future<int> depositMessage({
    required String channelBase,
    required String agentId,
    required String callerFp,
    required String messageId,
    required String sessionId,
    required String ciphertext,
  }) async {
    final uri = Uri.parse(
      '$channelBase/api/v1/mailbox/${Uri.encodeComponent(agentId)}/messages',
    );
    final resp = await _client
        .post(
          uri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'caller_fp': callerFp,
            'message_id': messageId,
            'session_id': sessionId,
            'ciphertext': ciphertext,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      throw ChannelMailboxException(
        'deposit failed HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['pending'] as num?)?.toInt() ?? 0;
  }

  Future<List<MailboxReply>> fetchReplies({
    required String channelBase,
    required String agentId,
    required String callerFp,
    String? after,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'caller_fp': callerFp,
      'limit': '$limit',
    };
    if (after != null && after.isNotEmpty) params['after'] = after;
    final uri = Uri.parse(
      '$channelBase/api/v1/mailbox/${Uri.encodeComponent(agentId)}/replies',
    ).replace(queryParameters: params);
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw ChannelMailboxException(
        'fetch replies HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (data['replies'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MailboxReply.fromJson)
        .toList();
  }

  Future<void> ackReplies({
    required String channelBase,
    required String agentId,
    required String callerFp,
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return;
    final uri = Uri.parse(
      '$channelBase/api/v1/mailbox/${Uri.encodeComponent(agentId)}/replies/ack',
    );
    final resp = await _client
        .post(
          uri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'caller_fp': callerFp, 'ids': ids}),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      LoggerService().debug(
        'ChannelMailboxService ack failed: ${resp.statusCode}',
        tag: 'Mailbox',
      );
    }
  }
}
