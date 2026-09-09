import 'dart:convert';

/// She 对单个 Agent 的紧凑认知索引（权威摘要 + She 观察 + 派发经验）。
///
/// 存储在 `she_memory.db` 的 `agent_impressions_index` 键下，供 She 1:1
/// prompt 注入；更细的资料通过 `agents.get --sections <...>` 按需拉取。
///
/// [sheObservations] 是 She 侧私有观察（派发结果、memory-write 同步），
/// 与 agent 储物袋里的 memory 分离。
class SheAgentImpression {
  final String agentId;
  final String agentName;
  final String oneLineRole;
  final String? experienceHint;
  final int lastVerifiedAt;
  final Map<String, int> dispatchStats;
  final List<String> sheObservations;

  const SheAgentImpression({
    required this.agentId,
    required this.agentName,
    required this.oneLineRole,
    this.experienceHint,
    required this.lastVerifiedAt,
    this.dispatchStats = const {},
    this.sheObservations = const [],
  });

  Map<String, dynamic> toJson() => {
        'agent_id': agentId,
        'agent_name': agentName,
        'one_line_role': oneLineRole,
        if (experienceHint != null && experienceHint!.isNotEmpty)
          'experience_hint': experienceHint,
        'last_verified_at': lastVerifiedAt,
        if (dispatchStats.isNotEmpty) 'dispatch_stats': dispatchStats,
        if (sheObservations.isNotEmpty) 'she_observations': sheObservations,
      };

  factory SheAgentImpression.fromJson(Map<String, dynamic> json) {
    final statsRaw = json['dispatch_stats'];
    Map<String, int> stats = const {};
    if (statsRaw is Map) {
      stats = statsRaw.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
      );
    }
    final obsRaw = json['she_observations'];
    List<String> observations = const [];
    if (obsRaw is List) {
      observations = obsRaw.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
    }
    return SheAgentImpression(
      agentId: json['agent_id'] as String? ?? '',
      agentName: json['agent_name'] as String? ?? '',
      oneLineRole: json['one_line_role'] as String? ?? '',
      experienceHint: json['experience_hint'] as String?,
      lastVerifiedAt: (json['last_verified_at'] as num?)?.toInt() ?? 0,
      dispatchStats: stats,
      sheObservations: observations,
    );
  }

  SheAgentImpression copyWith({
    String? agentId,
    String? agentName,
    String? oneLineRole,
    String? experienceHint,
    int? lastVerifiedAt,
    Map<String, int>? dispatchStats,
    List<String>? sheObservations,
  }) {
    return SheAgentImpression(
      agentId: agentId ?? this.agentId,
      agentName: agentName ?? this.agentName,
      oneLineRole: oneLineRole ?? this.oneLineRole,
      experienceHint: experienceHint ?? this.experienceHint,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      dispatchStats: dispatchStats ?? this.dispatchStats,
      sheObservations: sheObservations ?? this.sheObservations,
    );
  }

  static Map<String, SheAgentImpression> decodeIndex(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, SheAgentImpression>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final impression = SheAgentImpression.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (impression.agentId.isEmpty) continue;
        out[impression.agentId] = impression;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static String encodeIndex(Map<String, SheAgentImpression> index) {
    final jsonMap = {
      for (final e in index.entries) e.key: e.value.toJson(),
    };
    return jsonEncode(jsonMap);
  }
}

/// 待注入 She 1:1 prompt 的一次性 agent 变更通知。
class SheAgentImpressionAnnouncement {
  final String agentId;
  final String agentName;
  final String oneLineRole;
  final String kind;
  final String? previousOneLineRole;
  final int createdAt;

  const SheAgentImpressionAnnouncement({
    required this.agentId,
    required this.agentName,
    required this.oneLineRole,
    required this.kind,
    this.previousOneLineRole,
    required this.createdAt,
  });

  bool get isNew => kind == 'new';
  bool get isUpdated => kind == 'updated';

  Map<String, dynamic> toJson() => {
        'agent_id': agentId,
        'agent_name': agentName,
        'one_line_role': oneLineRole,
        'kind': kind,
        if (previousOneLineRole != null && previousOneLineRole!.isNotEmpty)
          'previous_one_line_role': previousOneLineRole,
        'created_at': createdAt,
      };

  factory SheAgentImpressionAnnouncement.fromJson(Map<String, dynamic> json) {
    return SheAgentImpressionAnnouncement(
      agentId: json['agent_id'] as String? ?? '',
      agentName: json['agent_name'] as String? ?? '',
      oneLineRole: json['one_line_role'] as String? ?? '',
      kind: json['kind'] as String? ?? 'new',
      previousOneLineRole: json['previous_one_line_role'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  static List<SheAgentImpressionAnnouncement> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map)
            SheAgentImpressionAnnouncement.fromJson(
              Map<String, dynamic>.from(item),
            ),
      ].where((a) => a.agentId.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<SheAgentImpressionAnnouncement> items) {
    return jsonEncode(items.map((e) => e.toJson()).toList());
  }
}
