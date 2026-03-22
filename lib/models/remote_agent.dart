import 'dart:convert';

import 'model_routing_config.dart';
import 'llm_provider_config.dart';
import '../services/channel_tunnel_service.dart';

/// Detect and repair a string corrupted by a UTF-16 encoding bug.
///
/// On some Android devices / IMEs, pasting text into an `obscureText` field
/// causes each ASCII byte to be stored as `(byte << 8) | 0x00`, producing
/// CJK-range codepoints.  This detects the pattern and recovers the original
/// ASCII string.
String repairUtf16Garbled(String s) {
  if (s.length < 2) return s;
  final units = s.codeUnits;
  if (units.every((u) => u > 127 && (u & 0xFF) == 0)) {
    return String.fromCharCodes(units.map((u) => (u >> 8) & 0xFF));
  }
  return s;
}

/// Recursively repair all string values in a metadata map.
Map<String, dynamic> _repairMetadata(Map<String, dynamic> m) {
  return m.map((key, value) {
    if (value is String) {
      return MapEntry(key, repairUtf16Garbled(value));
    }
    return MapEntry(key, value);
  });
}

/// 协议类型
enum ProtocolType {
  acp,
  custom;

  String toJson() => name;

  static ProtocolType fromJson(String value) {
    return ProtocolType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ProtocolType.acp,
    );
  }
}

/// 连接类型
enum ConnectionType {
  websocket,
  http;

  String toJson() => name;

  static ConnectionType fromJson(String value) {
    return ConnectionType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ConnectionType.websocket,
    );
  }
}

/// 助手状态
enum AgentStatus {
  online,
  offline,
  error;

  String toJson() => name;

  static AgentStatus fromJson(String value) {
    return AgentStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgentStatus.offline,
    );
  }
}

/// 远端助手模型
class RemoteAgent {
  /// App生成的UUID
  final String id;

  /// 助手显示名称
  final String name;

  /// 头像 emoji/URL
  final String avatar;

  /// 助手描述
  final String? bio;

  // 连接配置
  /// UUID token（用于助手认证）
  final String token;

  /// WebSocket/HTTP 端点 URL
  final String endpoint;

  /// 协议类型
  final ProtocolType protocol;

  /// 连接类型
  final ConnectionType connectionType;

  // 状态
  /// 助手状态
  final AgentStatus status;

  /// 最后心跳时间（毫秒时间戳）
  final int? lastHeartbeat;

  /// 连接时间（毫秒时间戳）
  final int? connectedAt;

  // 能力
  /// 能力列表
  final List<String> capabilities;

  /// 元数据
  final Map<String, dynamic> metadata;

  /// 创建时间（毫秒时间戳）
  final int createdAt;

  /// 更新时间（毫秒时间戳）
  final int updatedAt;

  /// 是否置顶（She 永远置顶）
  final bool isPinned;

  RemoteAgent({
    required this.id,
    required this.name,
    this.avatar = '🤖',
    this.bio,
    required this.token,
    required this.endpoint,
    required this.protocol,
    required this.connectionType,
    this.status = AgentStatus.offline,
    this.lastHeartbeat,
    this.connectedAt,
    this.capabilities = const [],
    this.metadata = const {},
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
  });

  /// 从 JSON 创建
  factory RemoteAgent.fromJson(Map<String, dynamic> json) {
    return RemoteAgent(
      id: json['id'] as String,
      name: json['name'] as String,
      avatar: json['avatar'] as String? ?? '🤖',
      bio: json['bio'] as String?,
      token: json['token'] as String,
      endpoint: json['endpoint'] as String,
      protocol: ProtocolType.fromJson(json['protocol'] as String),
      connectionType: ConnectionType.fromJson(json['connection_type'] as String),
      status: AgentStatus.fromJson(json['status'] as String? ?? 'offline'),
      lastHeartbeat: json['last_heartbeat'] as int?,
      connectedAt: json['connected_at'] as int?,
      capabilities: json['capabilities'] != null
          ? (jsonDecode(json['capabilities'] as String) as List).cast<String>()
          : [],
      metadata: json['metadata'] != null
          ? _repairMetadata(
              jsonDecode(json['metadata'] as String) as Map<String, dynamic>)
          : {},
      createdAt: json['created_at'] as int,
      updatedAt: json['updated_at'] as int,
      isPinned: (json['is_pinned'] as int? ?? 0) == 1,
    );
  }

  /// 从数据库行创建
  factory RemoteAgent.fromMap(Map<String, dynamic> map) {
    return RemoteAgent.fromJson(map);
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avatar': avatar,
      'bio': bio,
      'token': token,
      'endpoint': endpoint,
      'protocol': protocol.toJson(),
      'connection_type': connectionType.toJson(),
      'status': status.toJson(),
      'last_heartbeat': lastHeartbeat,
      'connected_at': connectedAt,
      'capabilities': jsonEncode(capabilities),
      'metadata': jsonEncode(metadata),
      'created_at': createdAt,
      'updated_at': updatedAt,
      'is_pinned': isPinned ? 1 : 0,
    };
  }

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() {
    return toJson();
  }

  /// 复制并修改部分字段
  RemoteAgent copyWith({
    String? id,
    String? name,
    String? avatar,
    String? bio,
    String? token,
    String? endpoint,
    ProtocolType? protocol,
    ConnectionType? connectionType,
    AgentStatus? status,
    int? lastHeartbeat,
    int? connectedAt,
    List<String>? capabilities,
    Map<String, dynamic>? metadata,
    int? createdAt,
    int? updatedAt,
    bool? isPinned,
  }) {
    return RemoteAgent(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      bio: bio ?? this.bio,
      token: token ?? this.token,
      endpoint: endpoint ?? this.endpoint,
      protocol: protocol ?? this.protocol,
      connectionType: connectionType ?? this.connectionType,
      status: status ?? this.status,
      lastHeartbeat: lastHeartbeat ?? this.lastHeartbeat,
      connectedAt: connectedAt ?? this.connectedAt,
      capabilities: capabilities ?? this.capabilities,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isPinned: isPinned ?? this.isPinned,
    );
  }

  /// Enabled OS tools (from metadata).
  Set<String> get enabledOsTools {
    final tools = metadata['enabled_os_tools'];
    if (tools is List) return Set<String>.from(tools.cast<String>());
    return {};
  }

  /// Whether any OS tools are enabled.
  bool get hasOsTools => enabledOsTools.isNotEmpty;

  /// Enabled skills (from metadata).
  Set<String> get enabledSkills {
    final skills = metadata['enabled_skills'];
    if (skills is List) return Set<String>.from(skills.cast<String>());
    return {};
  }

  /// Whether any skills are enabled.
  bool get hasSkills => enabledSkills.isNotEmpty;

  /// Enabled tool models (from metadata).
  Set<String> get enabledToolModels {
    final models = metadata['enabled_tool_models'];
    if (models is List) return Set<String>.from(models.cast<String>());
    return {};
  }

  /// Per-agent scenario overrides for tool models (toolName → scenario).
  Map<String, String> get toolModelScenarios {
    final raw = metadata['tool_model_scenarios'];
    if (raw is Map) {
      return Map<String, String>.from(
        raw.map((k, v) => MapEntry(k.toString(), v.toString())),
      );
    }
    return {};
  }

  /// Whether any tool models are enabled.
  bool get hasToolModels => enabledToolModels.isNotEmpty;

  /// Multi-modal model routing configuration parsed from metadata.
  ModelRoutingConfig get modelRouting {
    final routing = metadata['model_routing'] as Map<String, dynamic>?;
    return ModelRoutingConfig.fromJson(routing);
  }

  /// Whether multi-modal model routing is configured.
  bool get hasModelRouting => !modelRouting.isEmpty;

  /// Whether this agent can handle content of the given [modality].
  ///
  /// - Text is always supported.
  /// - Remote ACP agents (no `llm_provider` metadata) are assumed capable.
  /// - Local agents check explicit model routing first, then fall back to
  ///   the provider's [defaultVisionModel] for image modality.
  bool supportsModality(ModalityType modality) {
    if (modality == ModalityType.text) return true;

    // Remote ACP agents — assume capable (remote side handles it).
    if (!metadata.containsKey('llm_provider')) return true;

    // Check explicit model_routing for the modality.
    final routing = modelRouting;
    if (!routing.isEmpty) {
      final route = routing.routes[modality];
      if (route != null && !route.isEmpty) return true;
    }

    // For image modality, check if provider has a default vision model.
    if (modality == ModalityType.image) {
      final provider = metadata['llm_provider'] as String? ?? 'openai';
      final apiBase = metadata['llm_api_base'] as String? ?? '';
      for (final p in llmProviders) {
        if (p.providerType == provider &&
            (apiBase.isEmpty || p.defaultApiBase == apiBase) &&
            p.defaultVisionModel != null) {
          return true;
        }
      }
    }

    return false;
  }

  /// 是否允许外部访问（仅本地 agent 有意义）
  bool get allowExternalAccess {
    return metadata['allow_external_access'] == true;
  }

  /// 该 agent 的公网 channel 配置（存 metadata['channel_config']）
  ChannelTunnelConfig? get channelConfig {
    final raw = metadata['channel_config'];
    if (raw == null) return null;
    return ChannelTunnelConfig.fromJson(Map<String, dynamic>.from(raw as Map));
  }

  /// 是否在线
  bool get isOnline => status == AgentStatus.online;

  /// 是否是 She（内置守护 Agent）
  bool get isShe => isPinned && name == 'She';

  /// 是否离线
  bool get isOffline => status == AgentStatus.offline;

  /// 是否有错误
  bool get hasError => status == AgentStatus.error;

  /// 获取状态显示文本
  String get statusText {
    switch (status) {
      case AgentStatus.online:
        return '在线';
      case AgentStatus.offline:
        return '离线';
      case AgentStatus.error:
        return '错误';
    }
  }

  /// 获取状态图标
  String get statusIcon {
    switch (status) {
      case AgentStatus.online:
        return '🟢';
      case AgentStatus.offline:
        return '🟡';
      case AgentStatus.error:
        return '🔴';
    }
  }

  /// 获取协议显示名称
  String get protocolName {
    switch (protocol) {
      case ProtocolType.acp:
        return 'ACP';
      case ProtocolType.custom:
        return '自定义';
    }
  }

  /// 获取连接类型显示名称
  String get connectionTypeName {
    switch (connectionType) {
      case ConnectionType.websocket:
        return 'WebSocket';
      case ConnectionType.http:
        return 'HTTP';
    }
  }

  @override
  String toString() {
    return 'RemoteAgent(id: $id, name: $name, status: $status, protocol: $protocol)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is RemoteAgent &&
        other.id == id &&
        other.name == name &&
        other.avatar == avatar &&
        other.bio == bio &&
        other.token == token &&
        other.endpoint == endpoint &&
        other.protocol == protocol &&
        other.connectionType == connectionType &&
        other.status == status;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      avatar,
      bio,
      token,
      endpoint,
      protocol,
      connectionType,
      status,
    );
  }
}
