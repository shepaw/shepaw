/// 频道成员
class ChannelMember {
  final String id;
  final String type;
  final String role;
  final int joinedAt;
  /// 群内自定义能力描述，为 null 时使用 agent 自身的能力描述
  final String? groupBio;

  ChannelMember({
    required this.id,
    required this.type,
    required this.role,
    required this.joinedAt,
    this.groupBio,
  });

  bool get isAgent => type == 'agent';
  bool get isUser => type == 'user';

  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    return ChannelMember(
      id: json['id'] ?? '',
      type: json['type'] ?? 'user',
      role: json['role'] ?? 'member',
      joinedAt: json['joined_at'] ?? 0,
      groupBio: json['group_bio'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'role': role,
      'joined_at': joinedAt,
      if (groupBio != null) 'group_bio': groupBio,
    };
  }
}

/// 频道 (对话/群聊)
class Channel {
  final String id;
  final String name;
  final String type;
  final List<ChannelMember> members;
  final String createdBy;
  final int createdAt;
  final String? description;
  final String? avatar;
  final bool isPrivate;
  final int? unreadCount;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final String? parentGroupId;
  /// 群聊自定义系统提示词，用于约束群内 Agent 行为
  final String? systemPrompt;
  /// 群聊循环编排最大轮次
  final int? maxLoopRounds;
  /// 群聊 @提及模式: 'adminOnly' (默认) 或 'allMembers'
  final String? mentionMode;
  /// Flow 模式：Admin 生成阶段化 FlowPlan，由 FlowExecutor 主动驱动执行
  final bool flowMode;

  /// 获取有效的最大循环轮次，默认 50
  int get effectiveMaxLoopRounds => maxLoopRounds ?? 50;

  /// 获取有效的提及模式，默认 adminOnly
  String get effectiveMentionMode => mentionMode ?? 'adminOnly';

  /// 是否为所有成员均可提及模式
  bool get isAllMembersMentionMode => effectiveMentionMode == 'allMembers';

  Channel({
    required this.id,
    required this.name,
    required this.type,
    required this.members,
    this.createdBy = '',
    this.createdAt = 0,
    this.description,
    this.avatar,
    this.isPrivate = true,
    this.unreadCount,
    this.lastMessage,
    this.lastMessageTime,
    this.parentGroupId,
    this.systemPrompt,
    this.maxLoopRounds,
    this.mentionMode,
    this.flowMode = false,
  });

  /// Returns the ID that links all sessions of the same group together.
  /// For the original group, this is its own ID.
  /// For child sessions, this is their parentGroupId.
  String get groupFamilyId => parentGroupId ?? (isGroup ? id : id);

  /// Factory constructor that accepts memberIds for convenience
  factory Channel.withMemberIds({
    required String id,
    required String name,
    required String type,
    required List<String> memberIds,
    String createdBy = '',
    int createdAt = 0,
    String? description,
    String? avatar,
    bool isPrivate = true,
    int? unreadCount,
    String? lastMessage,
    DateTime? lastMessageTime,
    String? parentGroupId,
    String? systemPrompt,
    int? maxLoopRounds,
    String? mentionMode,
    bool flowMode = false,
  }) {
    return Channel(
      id: id,
      name: name,
      type: type,
      members: memberIds.map((id) => ChannelMember(
        id: id,
        type: 'user',
        role: 'member',
        joinedAt: DateTime.now().millisecondsSinceEpoch,
      )).toList(),
      createdBy: createdBy,
      createdAt: createdAt,
      description: description,
      avatar: avatar,
      isPrivate: isPrivate,
      unreadCount: unreadCount,
      lastMessage: lastMessage,
      lastMessageTime: lastMessageTime,
      parentGroupId: parentGroupId,
      systemPrompt: systemPrompt,
      maxLoopRounds: maxLoopRounds,
      mentionMode: mentionMode,
      flowMode: flowMode,
    );
  }

  bool get isDM => type == 'dm';
  bool get isGroup => type == 'group';
  bool get isPublic => type == 'public';

  int get memberCount => members.length;

  List<String> get agentIds =>
      members.where((m) => m.isAgent).map((m) => m.id).toList();

  List<String> get memberIds =>
      members.map((m) => m.id).toList();

  /// Returns the admin agent ID, or null if no admin is set.
  String? get adminAgentId {
    final admin = members.where((m) => m.role == 'admin');
    return admin.isNotEmpty ? admin.first.id : null;
  }

  /// Returns true if the given agent ID is the admin.
  bool isAdmin(String agentId) =>
      members.any((m) => m.id == agentId && m.role == 'admin');

  /// Returns the group-specific bio for an agent, or null if not set.
  String? getGroupBio(String agentId) {
    final member = members.where((m) => m.id == agentId);
    return member.isNotEmpty ? member.first.groupBio : null;
  }

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      type: json['type'] ?? 'dm',
      members: (json['members'] as List?)
          ?.map((m) => ChannelMember.fromJson(m))
          .toList() ?? [],
      createdBy: json['created_by'] ?? '',
      createdAt: json['created_at'] ?? 0,
      description: json['metadata']?['description'],
      avatar: json['metadata']?['avatar'],
      isPrivate: json['is_private'] ?? true,
      unreadCount: json['unread_count'],
      parentGroupId: json['parent_group_id'],
      systemPrompt: json['metadata']?['system_prompt'],
      maxLoopRounds: json['metadata']?['max_loop_rounds'] as int?,
      mentionMode: json['metadata']?['mention_mode'],
      flowMode: json['flow_mode'] as bool? ?? false,
    );
  }

  Channel copyWith({
    String? id,
    String? name,
    String? type,
    List<ChannelMember>? members,
    String? createdBy,
    int? createdAt,
    String? description,
    String? avatar,
    bool? isPrivate,
    int? unreadCount,
    String? lastMessage,
    DateTime? lastMessageTime,
    String? parentGroupId,
    String? systemPrompt,
    int? maxLoopRounds,
    String? mentionMode,
    bool? flowMode,
  }) {
    return Channel(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      members: members ?? this.members,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      description: description ?? this.description,
      avatar: avatar ?? this.avatar,
      isPrivate: isPrivate ?? this.isPrivate,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      parentGroupId: parentGroupId ?? this.parentGroupId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      maxLoopRounds: maxLoopRounds ?? this.maxLoopRounds,
      mentionMode: mentionMode ?? this.mentionMode,
      flowMode: flowMode ?? this.flowMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'members': members.map((m) => m.toJson()).toList(),
      'created_by': createdBy,
      'created_at': createdAt,
      'metadata': {
        if (description != null) 'description': description,
        if (avatar != null) 'avatar': avatar,
        if (systemPrompt != null) 'system_prompt': systemPrompt,
        if (maxLoopRounds != null) 'max_loop_rounds': maxLoopRounds,
        if (mentionMode != null) 'mention_mode': mentionMode,
      },
      'is_private': isPrivate,
      if (flowMode) 'flow_mode': true,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (parentGroupId != null) 'parent_group_id': parentGroupId,
    };
  }
}
