import 'dart:convert';

/// Agent 记忆数据模型
/// 
/// 代表某个 Agent 的一条记忆记录（结构化或时间线条目）。
class AgentMemory {
  final String id;              // 唯一 ID（通常为 UUID）
  final String agentId;         // Agent ID
  final String key;             // 记忆键（如 'soul', 'note_001' 等）
  final String value;           // 记忆内容（纯文本）
  final int createdAt;          // 创建时间戳（毫秒）
  final int updatedAt;          // 最后更新时间戳（毫秒）
  final Map<String, dynamic>? metadata; // 可选元数据（如 'type', 'priority' 等）

  AgentMemory({
    required this.id,
    required this.agentId,
    required this.key,
    required this.value,
    required this.createdAt,
    required this.updatedAt,
    this.metadata,
  });

  /// 从 JSON 反序列化
  factory AgentMemory.fromJson(Map<String, dynamic> json) {
    return AgentMemory(
      id: json['id'] as String? ?? '',
      agentId: json['agentId'] as String? ?? json['agent_id'] as String? ?? '',
      key: json['key'] as String? ?? '',
      value: json['value'] as String? ?? '',
      createdAt: json['createdAt'] as int? ?? json['created_at'] as int? ?? 0,
      updatedAt: json['updatedAt'] as int? ?? json['updated_at'] as int? ?? 0,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() => {
    'id': id,
    'agentId': agentId,
    'key': key,
    'value': value,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (metadata != null) 'metadata': metadata,
  };

  /// 获取创建日期的格式化字符串
  String get createdAtFormatted {
    return DateTime.fromMillisecondsSinceEpoch(createdAt)
        .toLocal()
        .toString()
        .substring(0, 19);
  }

  /// 获取更新日期的格式化字符串
  String get updatedAtFormatted {
    return DateTime.fromMillisecondsSinceEpoch(updatedAt)
        .toLocal()
        .toString()
        .substring(0, 19);
  }

  /// 是否为最近创建的记忆（24小时内）
  bool get isRecent {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - createdAt < 24 * 60 * 60 * 1000;
  }

  @override
  String toString() => 'AgentMemory(id: $id, agentId: $agentId, key: $key)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentMemory &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          agentId == other.agentId &&
          key == other.key;

  @override
  int get hashCode => id.hashCode ^ agentId.hashCode ^ key.hashCode;

  /// 复制并修改某些字段
  AgentMemory copyWith({
    String? id,
    String? agentId,
    String? key,
    String? value,
    int? createdAt,
    int? updatedAt,
    Map<String, dynamic>? metadata,
  }) {
    return AgentMemory(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      key: key ?? this.key,
      value: value ?? this.value,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// 向量搜索结果
/// 
/// 表示语义搜索返回的一个结果项。
class SearchResult {
  final String docId;           // 文档 ID（对应 AgentMemory ID）
  final String agentId;         // Agent ID
  final Map<String, dynamic> metadata; // 元数据（包含记忆的 key、value 等）
  final double similarity;      // 相似度评分（0-1）

  SearchResult({
    required this.docId,
    required this.agentId,
    required this.metadata,
    required this.similarity,
  });

  /// 从 JSON 反序列化
  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      docId: json['docId'] as String? ?? '',
      agentId: json['agentId'] as String? ?? json['agent_id'] as String? ?? '',
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      similarity: (json['similarity'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() => {
    'docId': docId,
    'agentId': agentId,
    'metadata': metadata,
    'similarity': similarity,
  };

  /// 获取相似度百分比（0-100）
  int get similarityPercent => (similarity * 100).toInt();

  @override
  String toString() =>
      'SearchResult(docId: $docId, similarity: ${similarityPercent}%)';
}
