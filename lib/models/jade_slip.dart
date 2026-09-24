import 'package:uuid/uuid.dart';

import '../storage/store_protocol.dart';

/// 玉简条目：储物袋里的待办/笔记，供用户记录、Agent 勾选执行。
///
/// 落盘为 `store://notes/<device>/slips/<id>.json`，跨设备随储物袋镜像。
/// 附件落在同分区 `slips/<id>/files/`。
class JadeSlip {
  const JadeSlip({
    required this.id,
    required this.title,
    this.body = '',
    this.status = JadeSlipStatus.open,
    this.priority = JadeSlipPriority.none,
    this.items = const [],
    this.comments = const [],
    this.attachments = const [],
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

  /// 过程留言：用户在 App 里写、Agent 用 `shepaw notes comment` 追加。
  final List<JadeSlipComment> comments;

  final List<JadeSlipAttachment> attachments;
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

  /// 待办项（未勾选）。派发时只把待办交给 Agent，已完成的留在玉简里。
  List<JadeSlipItem> get openItems =>
      items.where((e) => !e.done).toList(growable: false);

  bool get hasOpenItems => items.any((e) => !e.done);

  bool get allItemsDone => items.isNotEmpty && items.every((e) => e.done);

  bool get isOpen =>
      status == JadeSlipStatus.open || status == JadeSlipStatus.inProgress;

  /// 新建后未填写任何内容的草稿：离开编辑时等同「后悔新建」，应撤销删除。
  ///
  /// [untitledTitle] 为创建时的占位标题（如「未题玉简」）。
  bool isBlankDraft({required String untitledTitle}) {
    final t = title.trim();
    final placeholder = untitledTitle.trim();
    if (t.isNotEmpty && t != placeholder) return false;
    if (body.trim().isNotEmpty) return false;
    if (items.isNotEmpty) return false;
    if (comments.isNotEmpty) return false;
    if (attachments.isNotEmpty) return false;
    if (assigneeAgentId.trim().isNotEmpty) return false;
    if (dueAtMs != null) return false;
    if (tags.isNotEmpty) return false;
    if (priority != JadeSlipPriority.none) return false;
    if (status != JadeSlipStatus.open) return false;
    return true;
  }

  String get relPath => 'slips/$id.json';

  /// 玉简正文记录：`slips/<id>.json`（不含附件 `slips/<id>/files/…`）。
  static bool isRecordPath(String path) {
    final parts = path.split('/');
    return parts.length == 2 &&
        parts.first == 'slips' &&
        parts.last.endsWith('.json');
  }

  static String? idFromRecordPath(String path) {
    if (!isRecordPath(path)) return null;
    final leaf = path.substring(path.lastIndexOf('/') + 1);
    return leaf.substring(0, leaf.length - '.json'.length);
  }

  JadeSlip copyWith({
    String? title,
    String? body,
    JadeSlipStatus? status,
    JadeSlipPriority? priority,
    List<JadeSlipItem>? items,
    List<JadeSlipComment>? comments,
    List<JadeSlipAttachment>? attachments,
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
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
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
        if (comments.isNotEmpty)
          'comments': [for (final c in comments) c.toJson()],
        if (attachments.isNotEmpty)
          'attachments': [for (final a in attachments) a.toJson()],
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
    final rawComments = json['comments'];
    final comments = <JadeSlipComment>[];
    if (rawComments is List) {
      for (final item in rawComments) {
        if (item is Map) {
          comments.add(JadeSlipComment.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    final rawAtt = json['attachments'];
    final attachments = <JadeSlipAttachment>[];
    if (rawAtt is List) {
      for (final item in rawAtt) {
        if (item is Map) {
          attachments.add(
            JadeSlipAttachment.fromJson(item.cast<String, dynamic>()),
          );
        }
      }
    }
    return JadeSlip(
      id: (json['id'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      body: json['body'] as String? ?? '',
      status: JadeSlipStatus.parse(json['status'] as String?),
      priority: JadeSlipPriority.parse(json['priority'] as String?),
      items: items,
      comments: comments,
      attachments: attachments,
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
  ///
  /// 两种收窄方式都会保留「待办 N/M 项」的进度摘要，Agent 仍看得到整体上下文：
  /// - [focusItem] 非空：只派发这一项（清单项右侧菜单的「交给 Agent」）。
  /// - [onlyOpenItems] 为 true：清单只列未完成项（顶栏「交给 Agent」只交待办）。
  String toAgentPrompt({JadeSlipItem? focusItem, bool onlyOpenItems = false}) {
    final scoped = focusItem != null
        ? <JadeSlipItem>[focusItem]
        : onlyOpenItems
            ? openItems
            : items;
    final buf = StringBuffer(
      focusItem != null
          ? '请执行玉简待办「$title」（id=$id）中的这一项：'
          : '请执行玉简待办「$title」（id=$id）。',
    )
      ..writeln()
      ..writeln('status: ${status.wire}')
      ..writeln('priority: ${priority.wire}');
    if (dueAtMs != null) {
      buf.writeln(
          'due: ${DateTime.fromMillisecondsSinceEpoch(dueAtMs!).toIso8601String()}');
    }
    if (scoped.isNotEmpty) {
      buf.writeln(scoped.length != items.length
          ? 'checklist（待办 ${scoped.length}/$itemCount 项，'
              '已完成 $doneCount 项）:'
          : 'checklist:');
      for (final item in scoped) {
        buf.writeln('- [${item.done ? 'x' : ' '}] ${item.text} (item=${item.id})');
      }
    } else if (items.isNotEmpty) {
      // 只交待办而待办为空：说清状态，别让 Agent 以为这条玉简没有清单。
      buf.writeln('checklist（$itemCount 项全部已完成，无待办）:');
    }
    if (attachments.isNotEmpty) {
      buf.writeln('attachments:');
      for (final a in attachments) {
        buf.writeln('- ${a.name} (attachment=${a.id} uri=${a.uriFor(deviceId)})');
      }
    }
    final notes = body.trim();
    if (notes.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('notes:')
        ..writeln(notes);
    }
    if (comments.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('comments:');
      for (final c in comments) {
        buf.writeln('- ${c.displayName}: ${c.text} (comment=${c.id})');
      }
    }
    buf
      ..writeln()
      ..writeln('请用 shepaw notes 读写进度，完成一项就勾一项，不要只口头答应：')
      ..writeln('- shepaw notes get --id $id')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --done true');
    // 只派发单项时不能建议 complete —— 那会把整条玉简标记为完成。
    if (focusItem == null) {
      buf.writeln('- shepaw notes complete --id $id');
    }
    buf.writeln('- shepaw notes comment --id $id --text "进度说明"');
    if (attachments.isNotEmpty) {
      buf.writeln('- shepaw store read --uri <attachment uri>');
    }
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

/// 玉简上的一条留言（用户或 Agent 写的过程记录）。
class JadeSlipComment {
  const JadeSlipComment({
    required this.id,
    required this.authorId,
    this.authorName = '',
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final int createdAt;

  String get displayName => authorName.isEmpty ? authorId : authorName;

  JadeSlipComment copyWith({String? text}) => JadeSlipComment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        text: text ?? this.text,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_id': authorId,
        'author_name': authorName,
        'text': text,
        'created_at': createdAt,
      };

  factory JadeSlipComment.fromJson(Map<String, dynamic> json) =>
      JadeSlipComment(
        id: (json['id'] as String? ?? '').trim(),
        authorId: (json['author_id'] as String? ?? '').trim(),
        authorName: (json['author_name'] as String? ?? '').trim(),
        text: json['text'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );

  static String newId() => JadeSlipItem.newId();
}

class JadeSlipAttachment {
  const JadeSlipAttachment({
    required this.id,
    required this.name,
    required this.path,
    this.sizeBytes = 0,
  });

  final String id;
  final String name;

  /// `notes` 分区内相对路径，如 `slips/<id>/files/<attId>-name.pdf`。
  final String path;
  final int sizeBytes;

  String uriFor(String deviceId) =>
      storeUriWithRef(StoreSpace.notes, deviceId, path);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        if (sizeBytes > 0) 'size': sizeBytes,
      };

  factory JadeSlipAttachment.fromJson(Map<String, dynamic> json) =>
      JadeSlipAttachment(
        id: (json['id'] as String? ?? '').trim(),
        name: (json['name'] as String? ?? '').trim(),
        path: (json['path'] as String? ?? '').trim(),
        sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
      );

  static String newId() => JadeSlipItem.newId();
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
