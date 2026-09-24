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
    this.goal = '',
    this.constraints = '',
    this.doneWhen = '',
    this.status = JadeSlipStatus.open,
    this.priority = JadeSlipPriority.none,
    this.items = const [],
    this.comments = const [],
    this.attachments = const [],
    this.assigneeAgentId = '',
    this.assigneeAgentName = '',
    this.dueAtMs,
    this.tags = const [],
    this.parentId = '',
    this.sourceItemId = '',
    this.blockedBySlipId = '',
    this.sourceInstructionId = '',
    this.removedItemIds = const [],
    required this.deviceId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String body;

  /// 人交给 Agent 的目标：这一次要达成什么。
  final String goal;

  /// 约束：不能做什么、必须遵守什么。Agent 拆给其他 Agent 时一并带上。
  final String constraints;

  /// 怎样算完成。人和 Agent 用同一句话验收。
  final String doneWhen;

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

  /// 父简。大事拆开后，子简指回这一条。
  final String parentId;

  /// 父简上被拆出来的那一项。
  final String sourceItemId;

  /// 被哪一条玉简堵住。空表示没有依赖。
  final String blockedBySlipId;

  /// 这条简来自哪条指令集。空表示人手建的。
  final String sourceInstructionId;

  /// 已删除的清单项 id。合并时用来避免把另一端已删的项加回来。
  final List<String> removedItemIds;

  /// 权威副本所在设备（写入该 device 目录，便于镜像回源）。
  final String deviceId;
  final int createdAt;
  final int updatedAt;

  int get doneCount =>
      items.where((e) => e.state == JadeSlipItemState.accepted).length;

  int get submittedCount =>
      items.where((e) => e.state == JadeSlipItemState.submitted).length;

  int get itemCount => items.length;

  /// 还要 Agent 动手的项：未提交，或被堵住。已提交的等验收，不再派出去。
  List<JadeSlipItem> get openItems => items
      .where((e) =>
          e.state == JadeSlipItemState.open ||
          e.state == JadeSlipItemState.blocked)
      .toList(growable: false);

  bool get hasOpenItems => openItems.isNotEmpty;

  bool get allItemsDone =>
      items.isNotEmpty &&
      items.every((e) => e.state == JadeSlipItemState.accepted);

  bool get isOpen =>
      status == JadeSlipStatus.open ||
      status == JadeSlipStatus.inProgress ||
      status == JadeSlipStatus.needsReview ||
      status == JadeSlipStatus.blocked;

  /// 新建后未填写任何内容的草稿：离开编辑时等同「后悔新建」，应撤销删除。
  ///
  /// [untitledTitle] 为创建时的占位标题（如「未题玉简」）。
  bool isBlankDraft({required String untitledTitle}) {
    final t = title.trim();
    final placeholder = untitledTitle.trim();
    if (t.isNotEmpty && t != placeholder) return false;
    if (body.trim().isNotEmpty) return false;
    if (goal.trim().isNotEmpty) return false;
    if (constraints.trim().isNotEmpty) return false;
    if (doneWhen.trim().isNotEmpty) return false;
    if (items.isNotEmpty) return false;
    if (comments.isNotEmpty) return false;
    if (attachments.isNotEmpty) return false;
    if (assigneeAgentId.trim().isNotEmpty) return false;
    if (dueAtMs != null) return false;
    if (tags.isNotEmpty) return false;
    if (parentId.trim().isNotEmpty) return false;
    if (sourceItemId.trim().isNotEmpty) return false;
    if (blockedBySlipId.trim().isNotEmpty) return false;
    if (sourceInstructionId.trim().isNotEmpty) return false;
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
    String? goal,
    String? constraints,
    String? doneWhen,
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
    String? parentId,
    String? sourceItemId,
    String? blockedBySlipId,
    String? sourceInstructionId,
    List<String>? removedItemIds,
    String? deviceId,
    int? updatedAt,
  }) {
    return JadeSlip(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      goal: goal ?? this.goal,
      constraints: constraints ?? this.constraints,
      doneWhen: doneWhen ?? this.doneWhen,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      items: items ?? this.items,
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
      assigneeAgentId: assigneeAgentId ?? this.assigneeAgentId,
      assigneeAgentName: assigneeAgentName ?? this.assigneeAgentName,
      dueAtMs: clearDue ? null : (dueAtMs ?? this.dueAtMs),
      tags: tags ?? this.tags,
      parentId: parentId ?? this.parentId,
      sourceItemId: sourceItemId ?? this.sourceItemId,
      blockedBySlipId: blockedBySlipId ?? this.blockedBySlipId,
      sourceInstructionId: sourceInstructionId ?? this.sourceInstructionId,
      removedItemIds: removedItemIds ?? this.removedItemIds,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 清单推导整简状态。已归档、或没有清单项时不自动改。
  ///
  /// 全部验收通过才是 done。还有人要做的是 open / in_progress。
  /// 都交上来了是 needs_review。只剩被堵住的是 blocked。
  JadeSlip withDerivedStatus({int? updatedAt}) {
    if (status == JadeSlipStatus.archived || items.isEmpty) {
      return updatedAt == null ? this : copyWith(updatedAt: updatedAt);
    }
    final JadeSlipStatus next;
    if (allItemsDone) {
      next = JadeSlipStatus.done;
    } else if (items.any((e) => e.state == JadeSlipItemState.open)) {
      next = items.any((e) => e.state != JadeSlipItemState.open)
          ? JadeSlipStatus.inProgress
          : JadeSlipStatus.open;
    } else if (items.any((e) => e.state == JadeSlipItemState.submitted)) {
      next = JadeSlipStatus.needsReview;
    } else if (items.any((e) => e.state == JadeSlipItemState.blocked)) {
      next = JadeSlipStatus.blocked;
    } else {
      next = JadeSlipStatus.open;
    }
    return copyWith(status: next, updatedAt: updatedAt);
  }

  /// 两台设备各写了一部分时按字段并，不拿整份 JSON 互相覆盖。
  static JadeSlip mergeCopies(JadeSlip a, JadeSlip b) {
    final newer = a.updatedAt >= b.updatedAt ? a : b;
    final older = identical(newer, a) ? b : a;
    final removed = <String>{
      ...newer.removedItemIds,
      ...older.removedItemIds,
    };
    final items = <String, JadeSlipItem>{};
    for (final item in [...older.items, ...newer.items]) {
      if (removed.contains(item.id)) continue;
      final prev = items[item.id];
      if (prev == null || item.updatedAt >= prev.updatedAt) {
        items[item.id] = item;
      }
    }
    final comments = <String, JadeSlipComment>{};
    for (final comment in [...older.comments, ...newer.comments]) {
      comments.putIfAbsent(comment.id, () => comment);
    }
    final attachments = <String, JadeSlipAttachment>{};
    for (final att in [...older.attachments, ...newer.attachments]) {
      attachments.putIfAbsent(att.id, () => att);
    }
    return newer
        .copyWith(
          items: items.values.toList(),
          comments: comments.values.toList(),
          attachments: attachments.values.toList(),
          removedItemIds: removed.toList(),
          updatedAt: newer.updatedAt,
        )
        .withDerivedStatus(updatedAt: newer.updatedAt);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        if (goal.isNotEmpty) 'goal': goal,
        if (constraints.isNotEmpty) 'constraints': constraints,
        if (doneWhen.isNotEmpty) 'done_when': doneWhen,
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
        if (parentId.isNotEmpty) 'parent_id': parentId,
        if (sourceItemId.isNotEmpty) 'source_item_id': sourceItemId,
        if (blockedBySlipId.isNotEmpty) 'blocked_by': blockedBySlipId,
        if (sourceInstructionId.isNotEmpty)
          'source_instruction_id': sourceInstructionId,
        if (removedItemIds.isNotEmpty) 'removed_items': removedItemIds,
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
      goal: json['goal'] as String? ?? '',
      constraints: json['constraints'] as String? ?? '',
      doneWhen: json['done_when'] as String? ?? '',
      status: JadeSlipStatus.parse(json['status'] as String?),
      priority: JadeSlipPriority.parse(json['priority'] as String?),
      items: items,
      comments: comments,
      attachments: attachments,
      assigneeAgentId: json['assignee_agent_id'] as String? ?? '',
      assigneeAgentName: json['assignee_agent_name'] as String? ?? '',
      dueAtMs: (json['due_at'] as num?)?.toInt(),
      tags: tags,
      parentId: (json['parent_id'] as String? ?? '').trim(),
      sourceItemId: (json['source_item_id'] as String? ?? '').trim(),
      blockedBySlipId: (json['blocked_by'] as String? ?? '').trim(),
      sourceInstructionId:
          (json['source_instruction_id'] as String? ?? '').trim(),
      removedItemIds: [
        for (final id in (json['removed_items'] as List? ?? const []))
          id.toString().trim(),
      ].where((id) => id.isNotEmpty).toList(),
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
        state: done
            ? JadeSlipItemState.accepted
            : JadeSlipItemState.open,
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
      '玉简「$title」（id=$id），待办 ${openItems.length}/$itemCount 项。'
      '请 shepaw notes get --id $id 现读，不要依赖对话里的旧副本。',
    )
      ..writeln()
      ..writeln('status: ${status.wire}')
      ..writeln('priority: ${priority.wire}');
    if (dueAtMs != null) {
      buf.writeln(
          'due: ${DateTime.fromMillisecondsSinceEpoch(dueAtMs!).toIso8601String()}');
    }
    final goalText = goal.trim();
    if (goalText.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('goal（人交给 Agent 的目标）:')
        ..writeln(goalText);
    }
    final constraintText = constraints.trim();
    if (constraintText.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('constraints（必须遵守）:')
        ..writeln(constraintText);
    }
    final doneText = doneWhen.trim();
    if (doneText.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('done when（怎样算完成）:')
        ..writeln(doneText);
    }
    if (scoped.isNotEmpty) {
      buf.writeln(scoped.length != items.length
          ? 'checklist（待办 ${scoped.length}/$itemCount 项，'
              '已完成 $doneCount 项）:'
          : 'checklist:');
      for (final item in scoped) {
        buf.writeln(
            '- [${item.state.mark}] ${item.text} (item=${item.id}${item.assigneeSuffix})');
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
      buf.writeln('comments: ${comments.length} 条，用 notes get 查看，不在这里展开');
    }
    buf
      ..writeln()
      ..writeln('人和 Agent、Agent 与 Agent 写回同一条玉简：')
      ..writeln('- shepaw notes get --id $id')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --done true  （提交，等验收）')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --assignee <agent_id>')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --block --reason "..."')
      ..writeln(
          '- shepaw notes item --id $id --item <itemId> --evidence <store-uri>')
      ..writeln('- shepaw notes accept --id $id --item <itemId>  （人验收）')
      ..writeln('- shepaw notes comment --id $id --item <itemId> --text "进度"');
    return buf.toString();
  }
}

class JadeSlipItem {
  const JadeSlipItem({
    required this.id,
    required this.text,
    this.state = JadeSlipItemState.open,
    this.assigneeAgentId = '',
    this.assigneeAgentName = '',
    this.actorId = '',
    this.actorName = '',
    this.sessionId = '',
    this.childSlipId = '',
    this.blockedReason = '',
    this.evidence = const [],
    this.updatedAt = 0,
  });

  final String id;
  final String text;
  final JadeSlipItemState state;

  /// 已验收。旧数据里的 `done: true` 读成 accepted。
  bool get done => state == JadeSlipItemState.accepted;

  final String assigneeAgentId;
  final String assigneeAgentName;
  final String actorId;
  final String actorName;

  /// Agent 提交这项时正在干活的会话。人可以从事项打开它。
  final String sessionId;

  /// 这项被拆成的子简。空表示还没有。
  final String childSlipId;
  final String blockedReason;
  final List<String> evidence;
  final int updatedAt;

  String get assigneeSuffix {
    if (assigneeAgentId.isEmpty && assigneeAgentName.isEmpty) return '';
    final who = assigneeAgentName.isEmpty ? assigneeAgentId : assigneeAgentName;
    return ' assignee=$who';
  }

  JadeSlipItem copyWith({
    String? text,
    JadeSlipItemState? state,
    String? assigneeAgentId,
    String? assigneeAgentName,
    bool clearAssignee = false,
    String? actorId,
    String? actorName,
    String? sessionId,
    String? childSlipId,
    String? blockedReason,
    List<String>? evidence,
    int? updatedAt,
  }) =>
      JadeSlipItem(
        id: id,
        text: text ?? this.text,
        state: state ?? this.state,
        assigneeAgentId:
            clearAssignee ? '' : (assigneeAgentId ?? this.assigneeAgentId),
        assigneeAgentName:
            clearAssignee ? '' : (assigneeAgentName ?? this.assigneeAgentName),
        actorId: actorId ?? this.actorId,
        actorName: actorName ?? this.actorName,
        sessionId: sessionId ?? this.sessionId,
        childSlipId: childSlipId ?? this.childSlipId,
        blockedReason: blockedReason ?? this.blockedReason,
        evidence: evidence ?? this.evidence,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'state': state.wire,
        'done': done,
        if (assigneeAgentId.isNotEmpty) 'assignee_agent_id': assigneeAgentId,
        if (assigneeAgentName.isNotEmpty)
          'assignee_agent_name': assigneeAgentName,
        if (actorId.isNotEmpty) 'actor_id': actorId,
        if (actorName.isNotEmpty) 'actor_name': actorName,
        if (sessionId.isNotEmpty) 'session_id': sessionId,
        if (childSlipId.isNotEmpty) 'child_slip_id': childSlipId,
        if (blockedReason.isNotEmpty) 'blocked_reason': blockedReason,
        if (evidence.isNotEmpty) 'evidence': evidence,
        if (updatedAt > 0) 'updated_at': updatedAt,
      };

  factory JadeSlipItem.fromJson(Map<String, dynamic> json) {
    final rawEvidence = json['evidence'];
    final evidence = <String>[];
    if (rawEvidence is List) {
      for (final e in rawEvidence) {
        final s = e.toString().trim();
        if (s.isNotEmpty) evidence.add(s);
      }
    } else if (rawEvidence is String && rawEvidence.trim().isNotEmpty) {
      evidence.add(rawEvidence.trim());
    }
    final rawState = json['state'] as String?;
    final state = rawState != null && rawState.trim().isNotEmpty
        ? JadeSlipItemState.parse(rawState)
        : (json['done'] == true
            ? JadeSlipItemState.accepted
            : JadeSlipItemState.open);
    return JadeSlipItem(
      id: (json['id'] as String? ?? '').trim(),
      text: (json['text'] as String? ?? '').trim(),
      state: state,
      assigneeAgentId: json['assignee_agent_id'] as String? ?? '',
      assigneeAgentName: json['assignee_agent_name'] as String? ?? '',
      actorId: json['actor_id'] as String? ?? '',
      actorName: json['actor_name'] as String? ?? '',
      sessionId: (json['session_id'] as String? ?? '').trim(),
      childSlipId: (json['child_slip_id'] as String? ?? '').trim(),
      blockedReason: json['blocked_reason'] as String? ?? '',
      evidence: evidence,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  static String newId() => const Uuid().v4().replaceAll('-', '').substring(0, 8);
}

enum JadeSlipItemState {
  open,
  submitted,
  accepted,
  blocked;

  String get wire => name;

  String get mark => switch (this) {
        open => ' ',
        submitted => '~',
        accepted => 'x',
        blocked => '!',
      };

  static JadeSlipItemState parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'submitted':
      case 'review':
        return submitted;
      case 'accepted':
      case 'done':
        return accepted;
      case 'blocked':
        return blocked;
      default:
        return open;
    }
  }
}

/// 玉简上的一条留言（用户或 Agent 写的过程记录）。
class JadeSlipComment {
  const JadeSlipComment({
    required this.id,
    required this.authorId,
    this.authorName = '',
    this.itemId = '',
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorName;

  /// 挂在某一项上。空表示整简留言。
  final String itemId;
  final String text;
  final int createdAt;

  String get displayName => authorName.isEmpty ? authorId : authorName;

  JadeSlipComment copyWith({String? text}) => JadeSlipComment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        itemId: itemId,
        text: text ?? this.text,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_id': authorId,
        'author_name': authorName,
        if (itemId.isNotEmpty) 'item_id': itemId,
        'text': text,
        'created_at': createdAt,
      };

  factory JadeSlipComment.fromJson(Map<String, dynamic> json) =>
      JadeSlipComment(
        id: (json['id'] as String? ?? '').trim(),
        authorId: (json['author_id'] as String? ?? '').trim(),
        authorName: (json['author_name'] as String? ?? '').trim(),
        itemId: (json['item_id'] as String? ?? '').trim(),
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
  needsReview,
  blocked,
  done,
  archived;

  String get wire => switch (this) {
        open => 'open',
        inProgress => 'in_progress',
        needsReview => 'needs_review',
        blocked => 'blocked',
        done => 'done',
        archived => 'archived',
      };

  static JadeSlipStatus parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'in_progress':
      case 'doing':
        return inProgress;
      case 'needs_review':
      case 'review':
        return needsReview;
      case 'blocked':
        return blocked;
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
