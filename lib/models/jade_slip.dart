import 'package:uuid/uuid.dart';

/// 玉简条目：储物袋里的待办/笔记，供用户记录、Agent 勾选执行。
///
/// 落盘为 `store://notes/<device>/slips/<id>.json`，跨设备随储物袋镜像。
class JadeSlip {
  const JadeSlip({
    required this.id,
    required this.title,
    this.body = '',
    this.status = JadeSlipStatus.open,
    this.priority = JadeSlipPriority.none,
    this.items = const [],
    this.assigneeAgentId = '',
    this.assigneeAgentName = '',
    this.dueAtMs,
    this.tags = const [],
    required this.deviceId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String body;
  final JadeSlipStatus status;
  final JadeSlipPriority priority;
  final List<JadeSlipItem> items;
  final String assigneeAgentId;
  final String assigneeAgentName;
  final int? dueAtMs;
  final List<String> tags;

  /// 权威副本所在设备（写入该 device 目录，便于镜像回源）。
  final String deviceId;
  final int createdAt;
  final int updatedAt;

  int get doneCount => items.where((e) => e.done).length;

  int get itemCount => items.length;

  bool get hasOpenItems => items.any((e) => !e.done);

  bool get allItemsDone => items.isNotEmpty && items.every((e) => e.done);

  bool get isOpen =>
      status == JadeSlipStatus.open || status == JadeSlipStatus.inProgress;

  String get relPath => 'slips/$id.json';

  JadeSlip copyWith({
    String? title,
    String? body,
    JadeSlipStatus? status,
    JadeSlipPriority? priority,
    List<JadeSlipItem>? items,
    String? assigneeAgentId,
    String? assigneeAgentName,
    int? dueAtMs,
    bool clearDue = false,
    List<String>? tags,
    String? deviceId,
    int? updatedAt,
  }) {
    return JadeSlip(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      items: items ?? this.items,
      assigneeAgentId: assigneeAgentId ?? this.assigneeAgentId,
      assigneeAgentName: assigneeAgentName ?? this.assigneeAgentName,
      dueAtMs: clearDue ? null : (dueAtMs ?? this.dueAtMs),
      tags: tags ?? this.tags,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 根据清单进度推导状态：全完成 → done；有勾选 → in_progress；否则 open。
  /// 已归档、或没有清单项时不自动改。
  JadeSlip withDerivedStatus({int? updatedAt}) {
    if (status == JadeSlipStatus.archived || items.isEmpty) {
      return updatedAt == null ? this : copyWith(updatedAt: updatedAt);
    }
    final next = allItemsDone
        ? JadeSlipStatus.done
        : (doneCount > 0 ? JadeSlipStatus.inProgress : JadeSlipStatus.open);
    return copyWith(status: next, updatedAt: updatedAt);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'status': status.wire,
        'priority': priority.wire,
        'items': [for (final item in items) item.toJson()],
        if (assigneeAgentId.isNotEmpty) 'assignee_agent_id': assigneeAgentId,
        if (assigneeAgentName.isNotEmpty)
          'assignee_agent_name': assigneeAgentName,
        if (dueAtMs != null) 'due_at': dueAtMs,
        if (tags.isNotEmpty) 'tags': tags,
        'device_id': deviceId,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory JadeSlip.fromJson(Map<String, dynamic> json, {String? deviceId}) {
    final rawItems = json['items'];
    final items = <JadeSlipItem>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map) {
          items.add(JadeSlipItem.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    final rawTags = json['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final t in rawTags) {
        final s = t.toString().trim();
        if (s.isNotEmpty) tags.add(s);
      }
    }
    return JadeSlip(
      id: (json['id'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      body: json['body'] as String? ?? '',
      status: JadeSlipStatus.parse(json['status'] as String?),
      priority: JadeSlipPriority.parse(json['priority'] as String?),
      items: items,
      assigneeAgentId: json['assignee_agent_id'] as String? ?? '',
      assigneeAgentName: json['assignee_agent_name'] as String? ?? '',
      dueAtMs: (json['due_at'] as num?)?.toInt(),
      tags: tags,
      deviceId: (json['device_id'] as String?)?.trim().isNotEmpty == true
          ? (json['device_id'] as String).trim()
          : (deviceId ?? ''),
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  /// 从正文抽出 `- [ ]` / `- [x]` 行，作为清单（不覆盖已有 items 时由调用方合并）。
  static List<JadeSlipItem> itemsFromMarkdown(String markdown) {
    final out = <JadeSlipItem>[];
    final re = RegExp(r'^\s*[-*]\s*\[([ xX])\]\s*(.+)$', multiLine: true);
    for (final match in re.allMatches(markdown)) {
      final text = match.group(2)?.trim() ?? '';
      if (text.isEmpty) continue;
      final done = match.group(1)!.toLowerCase() == 'x';
      out.add(JadeSlipItem(
        id: JadeSlipItem.newId(),
        text: text,
        done: done,
      ));
    }
    return out;
  }

  /// Agent 执行时的任务说明：结构化清单 + CLI 用法。
  String toAgentPrompt() {
    final buf = StringBuffer()
      ..writeln('请执行玉简待办「$title」（id=$id）。')
      ..writeln()
      ..writeln('status: ${status.wire}')
      ..writeln('priority: ${priority.wire}');
    if (dueAtMs != null) {
      buf.writeln(
          'due: ${DateTime.fromMillisecondsSinceEpoch(dueAtMs!).toIso8601String()}');
    }
    if (items.isNotEmpty) {
      buf.writeln('checklist:');
      for (final item in items) {
        buf.writeln('- [${item.done ? 'x' : ' '}] ${item.text} (item=${item.id})');
      }
    }
    final notes = body.trim();
    if (notes.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('notes:')
        ..writeln(notes);
    }
    buf
      ..writeln()
      ..writeln('请用 shepaw notes 读写进度，完成一项就勾一项，不要只口头答应：')
      ..writeln('- shepaw notes get --id $id')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --done true')
      ..writeln('- shepaw notes complete --id $id');
    return buf.toString();
  }
}

class JadeSlipItem {
  const JadeSlipItem({
    required this.id,
    required this.text,
    this.done = false,
  });

  final String id;
  final String text;
  final bool done;

  JadeSlipItem copyWith({String? text, bool? done}) => JadeSlipItem(
        id: id,
        text: text ?? this.text,
        done: done ?? this.done,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'done': done,
      };

  factory JadeSlipItem.fromJson(Map<String, dynamic> json) => JadeSlipItem(
        id: (json['id'] as String? ?? '').trim(),
        text: (json['text'] as String? ?? '').trim(),
        done: json['done'] == true,
      );

  /// 短 id，方便 Agent 在对话里抄写。
  static String newId() => const Uuid().v4().replaceAll('-', '').substring(0, 8);
}

enum JadeSlipStatus {
  open,
  inProgress,
  done,
  archived;

  String get wire => switch (this) {
        open => 'open',
        inProgress => 'in_progress',
        done => 'done',
        archived => 'archived',
      };

  static JadeSlipStatus parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'in_progress':
      case 'doing':
        return inProgress;
      case 'done':
      case 'completed':
        return done;
      case 'archived':
        return archived;
      default:
        return open;
    }
  }
}

enum JadeSlipPriority {
  none,
  low,
  medium,
  high;

  String get wire => switch (this) {
        none => 'none',
        low => 'low',
        medium => 'medium',
        high => 'high',
      };

  static JadeSlipPriority parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'low':
        return low;
      case 'medium':
        return medium;
      case 'high':
      case 'urgent':
        return high;
      default:
        return none;
    }
  }
}
