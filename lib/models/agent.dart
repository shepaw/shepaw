/// Agent 提供商信息
class AgentProvider {
  final String name;
  final String platform;
  final String type;
  final String? logo;

  const AgentProvider({
    required this.name,
    required this.platform,
    required this.type,
    this.logo,
  });

  factory AgentProvider.fromJson(Map<String, dynamic> json) {
    return AgentProvider(
      name: json['name'] ?? '',
      platform: json['platform'] ?? '',
      type: json['type'] ?? '',
      logo: json['logo'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'platform': platform,
      'type': type,
      if (logo != null) 'logo': logo,
    };
  }
}

/// Agent 状态
class AgentStatus {
  final String state;
  final int? connectedAt;
  final int? lastHeartbeat;

  const AgentStatus({
    required this.state,
    this.connectedAt,
    this.lastHeartbeat,
  });

  bool get isOnline => state == 'online';

  factory AgentStatus.fromJson(Map<String, dynamic> json) {
    return AgentStatus(
      state: json['state'] ?? 'offline',
      connectedAt: json['connected_at'],
      lastHeartbeat: json['last_heartbeat'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'state': state,
      if (connectedAt != null) 'connected_at': connectedAt,
      if (lastHeartbeat != null) 'last_heartbeat': lastHeartbeat,
    };
  }
}

/// Agent 信息
class Agent {
  final String id;
  final String name;
  final String avatar;
  final String? bio;
  final String? type;
  final String? description;
  final String? model;
  final String? systemPrompt;
  final double? temperature;
  final int? maxTokens;
  final List<String>? capabilities;
  final Map<String, dynamic>? metadata;
  final AgentProvider provider;
  final AgentStatus status;

  Agent({
    required this.id,
    required this.name,
    required this.avatar,
    this.bio,
    this.type,
    this.description,
    this.model,
    this.systemPrompt,
    this.temperature,
    this.maxTokens,
    this.capabilities,
    this.metadata,
    required this.provider,
    required this.status,
  });

  factory Agent.fromJson(Map<String, dynamic> json) {
    final registration = json['registration'] ?? json;
    final status = json['status'] ?? {'state': 'offline'};

    return Agent(
      id: registration['agent_id'] ?? registration['id'] ?? '',
      name: registration['name'] ?? '',
      avatar: registration['avatar'] ?? '🤖',
      bio: registration['bio'],
      type: registration['type'],
      description: registration['description'],
      model: registration['model'],
      systemPrompt: registration['system_prompt'],
      temperature: registration['temperature']?.toDouble(),
      maxTokens: registration['max_tokens'],
      capabilities: (registration['capabilities'] as List?)?.cast<String>(),
      metadata: registration['metadata'],
      provider: AgentProvider.fromJson(registration['provider'] ?? {}),
      status: AgentStatus.fromJson(status),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'agent_id': id,
      'name': name,
      'avatar': avatar,
      'bio': bio,
      if (type != null) 'type': type,
      if (description != null) 'description': description,
      if (model != null) 'model': model,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (capabilities != null) 'capabilities': capabilities,
      if (metadata != null) 'metadata': metadata,
      'provider': provider.toJson(),
    };
  }

  Agent copyWith({
    String? id,
    String? name,
    String? avatar,
    String? bio,
    String? type,
    String? description,
    String? model,
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    List<String>? capabilities,
    Map<String, dynamic>? metadata,
    AgentProvider? provider,
    AgentStatus? status,
  }) {
    return Agent(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      bio: bio ?? this.bio,
      type: type ?? this.type,
      description: description ?? this.description,
      model: model ?? this.model,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      capabilities: capabilities ?? this.capabilities,
      metadata: metadata ?? this.metadata,
      provider: provider ?? this.provider,
      status: status ?? this.status,
    );
  }
}
