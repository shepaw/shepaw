/// 任务级产物规划与聚合清单（`shared/tasks/<orchestrationId>/`）。
class GroupTaskArtifactPlanSlot {
  GroupTaskArtifactPlanSlot({
    required this.filename,
    required this.description,
    this.assignedAgent,
  });

  final String filename;
  final String description;
  final String? assignedAgent;

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'description': description,
        if (assignedAgent != null && assignedAgent!.isNotEmpty)
          'assigned_agent': assignedAgent,
      };

  static GroupTaskArtifactPlanSlot? fromJson(Map<String, dynamic> json) {
    final filename = json['filename'] as String?;
    if (filename == null || filename.trim().isEmpty) return null;
    return GroupTaskArtifactPlanSlot(
      filename: filename.trim(),
      description: (json['description'] as String?)?.trim() ?? '',
      assignedAgent: (json['assigned_agent'] as String?)?.trim(),
    );
  }
}

/// Admin 规划的产物落点（`artifact_plan.json`）。
class GroupTaskArtifactPlan {
  GroupTaskArtifactPlan({
    required this.orchestrationId,
    required this.storeTaskId,
    this.slots = const [],
    this.notes = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  static const schemaVersion = 1;

  final String orchestrationId;

  /// `shepaw store write --task` 的统一 task id，成员产物应写入此目录。
  final String storeTaskId;
  final List<GroupTaskArtifactPlanSlot> slots;
  final String notes;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'orchestration_id': orchestrationId,
        'store_task_id': storeTaskId,
        'slots': [for (final s in slots) s.toJson()],
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static GroupTaskArtifactPlan? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    final storeTaskId = json['store_task_id'] as String?;
    if (orchestrationId == null ||
        orchestrationId.isEmpty ||
        storeTaskId == null ||
        storeTaskId.isEmpty) {
      return null;
    }
    final slots = <GroupTaskArtifactPlanSlot>[];
    final rawSlots = json['slots'];
    if (rawSlots is List) {
      for (final raw in rawSlots) {
        if (raw is Map) {
          final slot = GroupTaskArtifactPlanSlot.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (slot != null) slots.add(slot);
        }
      }
    }
    return GroupTaskArtifactPlan(
      orchestrationId: orchestrationId,
      storeTaskId: storeTaskId.trim(),
      slots: slots,
      notes: (json['notes'] as String?)?.trim() ?? '',
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }

  String toAdminBlock() {
    final lines = <String>[
      '【产物落点规划】store write 统一使用 --task $storeTaskId',
    ];
    if (notes.trim().isNotEmpty) {
      lines.add('说明: ${notes.trim()}');
    }
    if (slots.isNotEmpty) {
      lines.add('预期产物:');
      for (final slot in slots) {
        final owner = slot.assignedAgent != null && slot.assignedAgent!.isNotEmpty
            ? '（${slot.assignedAgent}）'
            : '';
        lines.add('- ${slot.filename}$owner: ${slot.description}');
      }
    }
    return lines.join('\n');
  }
}

/// 单条已登记产物（`artifacts.json` 元素）。
class GroupTaskArtifactEntry {
  GroupTaskArtifactEntry({
    required this.uri,
    required this.label,
    this.category = '',
    this.producedBy = '',
    this.source = 'auto',
    DateTime? registeredAt,
  }) : registeredAt = registeredAt ?? DateTime.now();

  static const sourceAuto = 'auto';
  static const sourceMember = 'member';
  static const sourceAdmin = 'admin';

  final String uri;
  final String label;
  final String category;
  final String producedBy;

  /// auto | member | admin
  final String source;
  final DateTime registeredAt;

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'label': label,
        if (category.isNotEmpty) 'category': category,
        if (producedBy.isNotEmpty) 'produced_by': producedBy,
        'source': source,
        'registered_at': registeredAt.toIso8601String(),
      };

  static GroupTaskArtifactEntry? fromJson(Map<String, dynamic> json) {
    final uri = json['uri'] as String?;
    if (uri == null || uri.trim().isEmpty) return null;
    return GroupTaskArtifactEntry(
      uri: uri.trim(),
      label: (json['label'] as String?)?.trim() ?? '',
      category: (json['category'] as String?)?.trim() ?? '',
      producedBy: (json['produced_by'] as String?)?.trim() ?? '',
      source: (json['source'] as String?)?.trim().isNotEmpty == true
          ? (json['source'] as String).trim()
          : sourceAuto,
      registeredAt:
          DateTime.tryParse(json['registered_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

/// 任务级产物聚合清单（`artifacts.json`）。
class GroupTaskArtifactManifest {
  GroupTaskArtifactManifest({
    required this.orchestrationId,
    this.entries = const [],
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  static const schemaVersion = 1;

  final String orchestrationId;
  final List<GroupTaskArtifactEntry> entries;
  final DateTime updatedAt;

  GroupTaskArtifactManifest registerAll(
    Iterable<GroupTaskArtifactEntry> incoming,
  ) {
    final seen = {for (final e in entries) e.uri};
    final merged = [...entries];
    for (final entry in incoming) {
      final uri = entry.uri.trim();
      if (uri.isEmpty || !uri.startsWith('store://')) continue;
      if (seen.add(uri)) merged.add(entry);
    }
    return GroupTaskArtifactManifest(
      orchestrationId: orchestrationId,
      entries: merged,
      updatedAt: DateTime.now(),
    );
  }

  List<String> get uris => [for (final e in entries) e.uri];

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'orchestration_id': orchestrationId,
        'entries': [for (final e in entries) e.toJson()],
        'updated_at': updatedAt.toIso8601String(),
      };

  static GroupTaskArtifactManifest? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    if (orchestrationId == null || orchestrationId.isEmpty) return null;
    final entries = <GroupTaskArtifactEntry>[];
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final raw in rawEntries) {
        if (raw is Map) {
          final entry = GroupTaskArtifactEntry.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (entry != null) entries.add(entry);
        }
      }
    }
    return GroupTaskArtifactManifest(
      orchestrationId: orchestrationId,
      entries: entries,
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}
