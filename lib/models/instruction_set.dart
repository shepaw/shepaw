/// 指令集条目——在对话中可复用的一项任务指令。
///
/// [ownerAgentId] 记录生成该指令的 agent（指令所属 agent）；
/// 执行时（`instructions run` / UI 一键执行）自动路由回该 agent 执行。
class InstructionSet {
  const InstructionSet({
    required this.id,
    required this.name,
    this.description,
    required this.content,
    required this.ownerAgentId,
    this.ownerAgentName = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? description;
  final String content;
  final String ownerAgentId;

  /// 生成时快照的 agent 显示名（用于 UI 展示；agent 改名后不回写）。
  final String ownerAgentName;
  final int createdAt;
  final int updatedAt;

  factory InstructionSet.fromRow(Map<String, dynamic> row) => InstructionSet(
        id: row['id'] as String,
        name: row['name'] as String,
        description: row['description'] as String?,
        content: row['content'] as String,
        ownerAgentId: row['owner_agent_id'] as String,
        ownerAgentName: (row['owner_agent_name'] as String?) ?? '',
        createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'name': name,
        'description': description,
        'content': content,
        'owner_agent_id': ownerAgentId,
        'owner_agent_name': ownerAgentName,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  InstructionSet copyWith({
    String? name,
    String? description,
    String? content,
    String? ownerAgentId,
    String? ownerAgentName,
    int? updatedAt,
    bool clearDescription = false,
  }) =>
      InstructionSet(
        id: id,
        name: name ?? this.name,
        description: clearDescription
            ? null
            : (description ?? this.description),
        content: content ?? this.content,
        ownerAgentId: ownerAgentId ?? this.ownerAgentId,
        ownerAgentName: ownerAgentName ?? this.ownerAgentName,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
