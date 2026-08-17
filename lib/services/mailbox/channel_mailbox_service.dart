/// Channel mailbox REST client (app side): leave messages when agent is busy,
/// fetch sealed replies when entering a chat.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logger_service.dart';
import '../peer_key_utils.dart';
import '../../models/remote_agent.dart';

class ChannelMailboxException implements Exception {
  ChannelMailboxException(this.message);
  final String message;
  @override
  String toString() => 'ChannelMailboxException: $message';
}

/// Result of `GET /api/v1/agents/:id/presence` for an approved caller.
class AgentChannelPresence {
  AgentChannelPresence({
    required this.online,
    required this.busy,
    required this.authorized,
    this.activeCount = 0,
    this.capacity = 5,
  });

  final bool online;
  final bool busy;
  final bool authorized;
  final int activeCount;
  final int capacity;

  /// Offline or at capacity → skip the live tunnel body, use inbox.
  bool get useInbox => authorized && (!online || busy);

  factory AgentChannelPresence.fromJson(Map<String, dynamic> j) {
    final authorized = j.containsKey('last_seen_at');
    final capacity = (j['capacity'] as num?)?.toInt() ?? 5;
    final active = (j['active_count'] as num?)?.toInt() ?? 0;
    final busyFlag = j['busy'] as bool?;
    return AgentChannelPresence(
      online: j['online'] as bool? ?? false,
      busy: busyFlag ?? (capacity > 0 && active >= capacity),
      authorized: authorized,
      activeCount: active,
      capacity: capacity,
    );
  }
}

class MailboxReply {
  MailboxReply({
    required this.id,
    required this.messageId,
    required this.replyTo,
    required this.requestId,
    required this.sessionId,
    required this.groupId,
    required this.targetId,
    required this.kind,
    required this.ciphertext,
    required this.createdAt,
  });

  final String id;
  final String messageId;
  final String replyTo;
  final String requestId;
  final String sessionId;
  final String groupId;
  final String targetId;
  final String kind;
  final String ciphertext;
  final String createdAt;

  factory MailboxReply.fromJson(Map<String, dynamic> j) => MailboxReply(
        id: j['id'] as String,
        messageId: j['message_id'] as String? ?? '',
        replyTo: j['reply_to'] as String? ?? '',
        requestId: j['request_id'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        groupId: j['group_id'] as String? ?? '',
        targetId: j['target_id'] as String? ??
            j['agent_id'] as String? ??
            '',
        kind: j['kind'] as String? ?? 'chat',
        ciphertext: j['ciphertext'] as String,
        createdAt: j['created_at'] as String? ?? '',
      );
}

class ChannelMailboxService {
  ChannelMailboxService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Unified ACP agent id for all mailbox addressing (claim keys, fetch,
  /// subscribe): metadata `target_agent_id` wins, then the endpoint's
  /// `?agentId=` query, then the local agent id. Every derivation must go
  /// through this helper so poller claims and fetch-side checks agree.
  static String acpAgentIdFor(RemoteAgent agent) {
    final fromMeta = agent.metadata['target_agent_id'] as String?;
    if (fromMeta != null && fromMeta.isNotEmpty) return fromMeta;
    return resolveAgentId(agent.endpoint, fallback: agent.id);
  }

  /// True when [agent] uses Channel relay and has a peer pubkey for seal-box.
  static bool agentHasChannelInbox(RemoteAgent agent) {
    if (!isChannelRelayEndpoint(agent.endpoint)) return false;
    final pub = decodeCachedPeerPublicKey(
      agent.metadata['cached_peer_static_public_key'],
    );
    if (pub == null) return false;
    return acpAgentIdFor(agent).isNotEmpty;
  }

  /// Approved-caller presence probe. Returns null on network/HTTP failure.
  /// Unauthorized callers get `{online:false}` without `last_seen_at`.
  Future<AgentChannelPresence?> probePresence({
    required String channelBase,
    required String agentId,
    required String callerFp,
  }) async {
    final uri = Uri.parse(
      '$channelBase/api/v1/agents/${Uri.encodeComponent(agentId)}/presence',
    ).replace(queryParameters: {'caller_fp': callerFp});
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body);
      if (data is! Map<String, dynamic>) return null;
      return AgentChannelPresence.fromJson(data);
    } catch (e) {
      LoggerService().debug(
        'probePresence failed: $e',
        tag: 'ChannelMailboxService',
      );
      return null;
    }
  }

  /// True only for Channel Service relay URLs (`/proxy/<id>/…` or `/c/<alias>/…`).
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
    required String requestId,
    required String sessionId,
    required String ciphertext,
    String? groupId,
  }) async {
    final uri = Uri.parse(
      '$channelBase/api/v1/mailbox/${Uri.encodeComponent(agentId)}/messages',
    );
    final body = <String, dynamic>{
      'caller_fp': callerFp,
      'message_id': messageId,
      'request_id': requestId,
      'session_id': sessionId,
      'ciphertext': ciphertext,
    };
    if (groupId != null && groupId.isNotEmpty) {
      body['group_id'] = groupId;
    }
    final resp = await _client
        .post(
          uri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
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
    return _getReplies(uri);
  }

  /// Cross-target inbox fetch (app startup / unified pull).
  Future<List<MailboxReply>> fetchInboxReplies({
    required String channelBase,
    required String callerFp,
    String? after,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'caller_fp': callerFp,
      'limit': '$limit',
    };
    if (after != null && after.isNotEmpty) params['after'] = after;
    final uri = Uri.parse('$channelBase/api/v1/inbox/replies')
        .replace(queryParameters: params);
    return _getReplies(uri);
  }

  Future<List<MailboxReply>> _getReplies(Uri uri) async {
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
    await _postAck(uri, callerFp, ids);
  }

  Future<void> ackInboxReplies({
    required String channelBase,
    required String callerFp,
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return;
    final uri = Uri.parse('$channelBase/api/v1/inbox/replies/ack');
    await _postAck(uri, callerFp, ids);
  }

  Future<void> _postAck(Uri uri, String callerFp, List<String> ids) async {
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
