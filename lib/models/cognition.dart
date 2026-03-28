import 'dart:convert';

/// Agent 对自身的认知条目
///
/// 存储在 `minds.db` 的 `cognition_self` 表中，每个 Agent 一条。
/// soul 字段记录 Agent 的核心特质、价值观与自我理解。
class SelfCognition {
  /// 自增主键（插入前为 null）
  final int? id;

  /// Agent ID（UNIQUE，每个 Agent 只有一条记录）
  final String agentId;

  /// 核心特质与价值观（Soul）
  ///
  /// 对于 She：随对话成长的自我认知。
  /// 对于 Remote Agent：system_prompt（固定人格设定）。
  final String soul;

  /// 自我反思 / 内部备注（仅 She 使用）
  final String? selfNotes;

  /// 能力描述（JSON Map），可选
  final Map<String, dynamic>? capabilities;

  final int createdAt;
  final int updatedAt;

  const SelfCognition({
    this.id,
    required this.agentId,
    required this.soul,
    this.selfNotes,
    this.capabilities,
    required this.createdAt,
    required this.updatedAt,
  });

  // ---------------------------------------------------------------------------
  // SQLite 序列化
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'agent_id': agentId,
      'soul': soul,
      'self_notes': selfNotes,
      'capabilities': capabilities != null ? jsonEncode(capabilities) : null,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory SelfCognition.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? caps;
    final capRaw = map['capabilities'] as String?;
    if (capRaw != null && capRaw.isNotEmpty) {
      try {
        caps = jsonDecode(capRaw) as Map<String, dynamic>?;
      } catch (_) {}
    }

    return SelfCognition(
      id: map['id'] as int?,
      agentId: map['agent_id'] as String,
      soul: map['soul'] as String? ?? '',
      selfNotes: map['self_notes'] as String?,
      capabilities: caps,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  // ---------------------------------------------------------------------------
  // JSON 序列化
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'agentId': agentId,
        'soul': soul,
        'selfNotes': selfNotes,
        'capabilities': capabilities,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory SelfCognition.fromJson(Map<String, dynamic> json) {
    return SelfCognition(
      id: json['id'] as int?,
      agentId: json['agentId'] as String? ?? '',
      soul: json['soul'] as String? ?? '',
      selfNotes: json['selfNotes'] as String?,
      capabilities: json['capabilities'] as Map<String, dynamic>?,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  SelfCognition copyWith({
    int? id,
    String? agentId,
    String? soul,
    String? selfNotes,
    Map<String, dynamic>? capabilities,
    int? createdAt,
    int? updatedAt,
  }) {
    return SelfCognition(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      soul: soul ?? this.soul,
      selfNotes: selfNotes ?? this.selfNotes,
      capabilities: capabilities ?? this.capabilities,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() => 'SelfCognition(agentId: $agentId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelfCognition &&
          runtimeType == other.runtimeType &&
          agentId == other.agentId;

  @override
  int get hashCode => agentId.hashCode;
}

/// Agent 对用户的认知条目
///
/// 存储在 `minds.db` 的 `cognition_user` 表中，每个 Agent 一条。
/// 不同 Agent 对同一用户可能有不同的印象和理解。
class UserCognition {
  /// 自增主键（插入前为 null）
  final int? id;

  /// Agent ID（谁对用户的认知）
  final String agentId;

  /// 用户基本信息（KV Map，如 name/age/occupation 等）
  ///
  /// 存储为 JSON 字符串，读取后反序列化为 `Map<String, String>`。
  final Map<String, String> userProfile;

  /// Agent 的主观印象（如"主人喜欢简洁的回答"）
  final String? userImpression;

  /// 额外备注（如"主人提到有一只叫 Mochi 的猫"）
  final String? userNotes;

  final int lastUpdated;

  const UserCognition({
    this.id,
    required this.agentId,
    required this.userProfile,
    this.userImpression,
    this.userNotes,
    required this.lastUpdated,
  });

  // ---------------------------------------------------------------------------
  // SQLite 序列化
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'agent_id': agentId,
      'user_profile': jsonEncode(userProfile),
      'user_impression': userImpression,
      'user_notes': userNotes,
      'last_updated': lastUpdated,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory UserCognition.fromMap(Map<String, dynamic> map) {
    Map<String, String> profile = {};
    final profileRaw = map['user_profile'] as String? ?? '{}';
    try {
      final decoded = jsonDecode(profileRaw);
      if (decoded is Map) {
        profile = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}

    return UserCognition(
      id: map['id'] as int?,
      agentId: map['agent_id'] as String,
      userProfile: profile,
      userImpression: map['user_impression'] as String?,
      userNotes: map['user_notes'] as String?,
      lastUpdated: map['last_updated'] as int,
    );
  }

  // ---------------------------------------------------------------------------
  // JSON 序列化
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'agentId': agentId,
        'userProfile': userProfile,
        'userImpression': userImpression,
        'userNotes': userNotes,
        'lastUpdated': lastUpdated,
      };

  factory UserCognition.fromJson(Map<String, dynamic> json) {
    final kwRaw = json['userProfile'];
    final Map<String, String> profile = kwRaw is Map
        ? kwRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
        : {};

    return UserCognition(
      id: json['id'] as int?,
      agentId: json['agentId'] as String? ?? '',
      userProfile: profile,
      userImpression: json['userImpression'] as String?,
      userNotes: json['userNotes'] as String?,
      lastUpdated: (json['lastUpdated'] as num?)?.toInt() ?? 0,
    );
  }

  UserCognition copyWith({
    int? id,
    String? agentId,
    Map<String, String>? userProfile,
    String? userImpression,
    String? userNotes,
    int? lastUpdated,
  }) {
    return UserCognition(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      userProfile: userProfile ?? this.userProfile,
      userImpression: userImpression ?? this.userImpression,
      userNotes: userNotes ?? this.userNotes,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  @override
  String toString() => 'UserCognition(agentId: $agentId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserCognition &&
          runtimeType == other.runtimeType &&
          agentId == other.agentId;

  @override
  int get hashCode => agentId.hashCode;
}
