import 'dart:convert';

/// Agent 记忆类型枚举
enum MemoryType {
  /// 对话记忆 - 来自与用户的对话内容
  conversation,

  /// 知识/信息 - Agent 学习到的事实或信息
  knowledge,

  /// 行为模式 - Agent 观察到的用户行为规律
  behavior,

  /// 事件记录 - 发生的特定事件
  event,

  /// 情感状态 - 用户的情感或心理状态
  emotion;

  /// 从字符串反序列化（未知值默认为 conversation）
  static MemoryType fromString(String value) {
    return MemoryType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MemoryType.conversation,
    );
  }

  /// 获取显示名称（中文）
  String get displayName {
    switch (this) {
      case MemoryType.conversation:
        return '对话';
      case MemoryType.knowledge:
        return '知识';
      case MemoryType.behavior:
        return '行为';
      case MemoryType.event:
        return '事件';
      case MemoryType.emotion:
        return '情感';
    }
  }
}

/// 来源类型常量
class MemorySourceType {
  MemorySourceType._();

  /// 私聊来源
  static const String direct = 'direct';

  /// 群聊来源
  static const String group = 'group';

  /// 系统生成（非对话）
  static const String system = 'system';

  static const List<String> values = [direct, group, system];
}

/// Agent 记忆条目
///
/// 表示一个 Agent 的单条结构化记忆，存储在该 Agent 独立的 SQLite 数据库文件中。
///
/// ### 字段说明
/// - [memoryId]       自增整数主键，由数据库生成（插入前为 null）
/// - [syncKey]        跨设备同步稳定 ID（UUID，插入时自动生成）
/// - [memoryContent]  记忆内容（自由文本）
/// - [memoryTime]     记忆时间戳（毫秒），表示记忆发生的时间
/// - [memoryType]     记忆分类（[MemoryType] 枚举）
/// - [memoryKeywords] 关键词列表（用于搜索和归纳）
/// - [sourceType]     来源类型（[MemorySourceType] 常量，可为 null）
/// - [sourceId]       来源 ID（如 channel_id，可为 null）
/// - [createdAt]      记录写入时间（毫秒）
/// - [updatedAt]      记录最后更新时间（毫秒）
class AgentMemoryEntry {
  /// 自增主键，插入前为 null，写入后由数据库分配
  final int? memoryId;

  /// 跨设备同步用的稳定标识（UUID）
  final String? syncKey;
  final String memoryContent;
  final int memoryTime;
  final MemoryType memoryType;
  final List<String> memoryKeywords;
  final String? sourceType;
  final String? sourceId;
  final int createdAt;
  final int updatedAt;

  const AgentMemoryEntry({
    this.memoryId,
    this.syncKey,
    required this.memoryContent,
    required this.memoryTime,
    required this.memoryType,
    required this.memoryKeywords,
    this.sourceType,
    this.sourceId,
    required this.createdAt,
    required this.updatedAt,
  });

  // ---------------------------------------------------------------------------
  // SQLite 序列化
  // ---------------------------------------------------------------------------

  /// 转换为 SQLite 行 Map（memoryId 为 null 时不写入，让数据库自增）
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'memory_content': memoryContent,
      'memory_time': memoryTime,
      'memory_type': memoryType.name,
      'memory_keywords': jsonEncode(memoryKeywords),
      'source_type': sourceType,
      'source_id': sourceId,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
    if (memoryId != null) map['memory_id'] = memoryId;
    if (syncKey != null) map['sync_key'] = syncKey;
    return map;
  }

  /// 从 SQLite 行 Map 反序列化
  factory AgentMemoryEntry.fromMap(Map<String, dynamic> map) {
    final keywordsRaw = map['memory_keywords'] as String? ?? '[]';
    List<String> keywords;
    try {
      final decoded = jsonDecode(keywordsRaw);
      keywords = decoded is List
          ? decoded.map((e) => e.toString()).toList()
          : <String>[];
    } catch (_) {
      keywords = <String>[];
    }

    return AgentMemoryEntry(
      memoryId: map['memory_id'] as int?,
      syncKey: map['sync_key'] as String?,
      memoryContent: map['memory_content'] as String,
      memoryTime: map['memory_time'] as int,
      memoryType: MemoryType.fromString(map['memory_type'] as String? ?? ''),
      memoryKeywords: keywords,
      sourceType: map['source_type'] as String?,
      sourceId: map['source_id'] as String?,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  // ---------------------------------------------------------------------------
  // JSON 序列化
  // ---------------------------------------------------------------------------

  /// 转换为 JSON Map
  Map<String, dynamic> toJson() => {
        'memoryId': memoryId,
        'syncKey': syncKey,
        'memoryContent': memoryContent,
        'memoryTime': memoryTime,
        'memoryType': memoryType.name,
        'memoryKeywords': memoryKeywords,
        'sourceType': sourceType,
        'sourceId': sourceId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// 从 JSON Map 反序列化
  factory AgentMemoryEntry.fromJson(Map<String, dynamic> json) {
    final kwRaw = json['memoryKeywords'];
    final keywords = kwRaw is List
        ? kwRaw.map((e) => e.toString()).toList()
        : <String>[];

    return AgentMemoryEntry(
      memoryId: json['memoryId'] as int?,
      syncKey: json['syncKey'] as String?,
      memoryContent: json['memoryContent'] as String? ?? '',
      memoryTime: (json['memoryTime'] as num?)?.toInt() ?? 0,
      memoryType: MemoryType.fromString(json['memoryType'] as String? ?? ''),
      memoryKeywords: keywords,
      sourceType: json['sourceType'] as String?,
      sourceId: json['sourceId'] as String?,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  // ---------------------------------------------------------------------------
  // 工具方法
  // ---------------------------------------------------------------------------

  /// 复制并修改部分字段
  AgentMemoryEntry copyWith({
    int? memoryId,
    String? syncKey,
    String? memoryContent,
    int? memoryTime,
    MemoryType? memoryType,
    List<String>? memoryKeywords,
    String? sourceType,
    String? sourceId,
    int? createdAt,
    int? updatedAt,
  }) {
    return AgentMemoryEntry(
      memoryId: memoryId ?? this.memoryId,
      syncKey: syncKey ?? this.syncKey,
      memoryContent: memoryContent ?? this.memoryContent,
      memoryTime: memoryTime ?? this.memoryTime,
      memoryType: memoryType ?? this.memoryType,
      memoryKeywords: memoryKeywords ?? this.memoryKeywords,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 格式化记忆时间
  String get memoryTimeFormatted =>
      DateTime.fromMillisecondsSinceEpoch(memoryTime)
          .toLocal()
          .toString()
          .substring(0, 19);

  /// 格式化创建时间
  String get createdAtFormatted =>
      DateTime.fromMillisecondsSinceEpoch(createdAt)
          .toLocal()
          .toString()
          .substring(0, 19);

  /// 是否为私聊来源
  bool get isFromDirect => sourceType == MemorySourceType.direct;

  /// 是否为群聊来源
  bool get isFromGroup => sourceType == MemorySourceType.group;

  @override
  String toString() =>
      'AgentMemoryEntry(id: $memoryId, type: ${memoryType.name}, '
      'source: $sourceType/$sourceId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentMemoryEntry &&
          runtimeType == other.runtimeType &&
          memoryId == other.memoryId;

  @override
  int get hashCode => memoryId.hashCode;
}
