/// Channel-mediated agent access: discovery → request → poll approval → import.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_agent.dart';
import 'noise_identity.dart';
import 'remote_agent_service.dart';

const _prefChannelBase = 'shepaw.discovery.channel_base';

class AgentAccessException implements Exception {
  AgentAccessException(this.message);
  final String message;
  @override
  String toString() => 'AgentAccessException: $message';
}

class PublicAgentCard {
  PublicAgentCard({
    required this.agentId,
    required this.name,
    required this.description,
    required this.agentFp,
    required this.capacity,
    required this.online,
  });

  final String agentId;
  final String name;
  final String description;
  final String agentFp;
  final int capacity;
  final bool online;

  factory PublicAgentCard.fromJson(Map<String, dynamic> j) => PublicAgentCard(
        agentId: j['agent_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        agentFp: j['agent_fp'] as String? ?? '',
        capacity: (j['capacity'] as num?)?.toInt() ?? 5,
        online: j['online'] as bool? ?? false,
      );
}

class AccessRequestStatus {
  AccessRequestStatus({
    required this.id,
    required this.agentId,
    required this.status,
    this.endpoint,
    this.agentFp,
    this.agentPubkey,
    this.agentName,
  });

  final String id;
  final String agentId;
  final String status;
  final String? endpoint;
  final String? agentFp;
  final String? agentPubkey;
  final String? agentName;

  bool get isApproved => status == 'approved';

  factory AccessRequestStatus.fromJson(Map<String, dynamic> j) =>
      AccessRequestStatus(
        id: j['id'] as String? ?? '',
        agentId: j['agent_id'] as String? ?? '',
        status: j['status'] as String? ?? '',
        endpoint: j['endpoint'] as String?,
        agentFp: j['agent_fp'] as String?,
        agentPubkey: j['agent_pubkey'] as String?,
        agentName: j['agent_name'] as String?,
      );
}

class AgentAccessService {
  AgentAccessService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static Future<String?> loadChannelBase() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefChannelBase);
  }

  static Future<void> saveChannelBase(String base) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefChannelBase, base.replaceAll(RegExp(r'/+$'), ''));
  }

  Future<List<PublicAgentCard>> search({
    required String channelBase,
    String query = '',
    int page = 1,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'page_size': '20',
    };
    if (query.trim().isNotEmpty) params['q'] = query.trim();
    final uri = Uri.parse('$channelBase/api/v1/discovery/agents')
        .replace(queryParameters: params);
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw AgentAccessException('search HTTP ${resp.statusCode}: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (data['agents'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(PublicAgentCard.fromJson)
        .toList();
  }

  Future<AccessRequestStatus> requestAccess({
    required String channelBase,
    required String agentId,
    String? callerName,
    String? message,
  }) async {
    final identity = await NoiseIdentity.loadOrCreate();
    final resp = await _client
        .post(
          Uri.parse('$channelBase/api/v1/access-requests'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'agent_id': agentId,
            'caller_fp': identity.fingerprintHex,
            'caller_pubkey': identity.publicKeyBase64,
            if (callerName != null && callerName.isNotEmpty)
              'caller_name': callerName,
            if (message != null && message.isNotEmpty) 'message': message,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw AgentAccessException(
        'request HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    return AccessRequestStatus.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  Future<AccessRequestStatus?> getMine({
    required String channelBase,
    required String agentId,
  }) async {
    final identity = await NoiseIdentity.loadOrCreate();
    final uri = Uri.parse('$channelBase/api/v1/access-requests/mine')
        .replace(queryParameters: {
      'agent_id': agentId,
      'caller_fp': identity.fingerprintHex,
    });
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw AgentAccessException('status HTTP ${resp.statusCode}: ${resp.body}');
    }
    return AccessRequestStatus.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// When approved, persist a local RemoteAgent ready for Noise connect
  /// (no enrollment code — pubkey already on allowlist).
  Future<RemoteAgent> importApproved({
    required AccessRequestStatus status,
    required RemoteAgentService remoteAgentService,
  }) async {
    if (!status.isApproved) {
      throw AgentAccessException('not approved yet');
    }
    final endpoint = status.endpoint ?? '';
    if (endpoint.isEmpty) {
      throw AgentAccessException('approved but endpoint missing');
    }
    final pubkey = status.agentPubkey ?? '';
    if (pubkey.isEmpty) {
      throw AgentAccessException(
        'approved but agent_pubkey missing — wait for agent re-register',
      );
    }

    return remoteAgentService.createAgent(
      name: status.agentName?.isNotEmpty == true
          ? status.agentName!
          : status.agentId,
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      endpoint: endpoint,
      bio: 'Via channel access grant',
      metadata: {
        'target_agent_id': status.agentId,
        'cached_peer_static_public_key': pubkey,
        if (status.agentFp != null) 'expected_fingerprint': status.agentFp,
        'from_access_grant': true,
      },
    );
  }
}
