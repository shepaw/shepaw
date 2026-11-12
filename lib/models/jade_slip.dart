import 'package:uuid/uuid.dart';

import '../storage/store_protocol.dart';

/// 玉简的执行者：单个 Agent（缺省、旧数据）或一个工作流模板。
///
/// 旧玉简没有 `executor_kind` 字段，一律按 agent 处理，无需迁移。
enum JadeSlipExecutorKind {
  agent,
  flow;

  String get wire => switch (this) {
        agent => 'agent',
        flow => 'flow',
      };

  static JadeSlipExecutorKind parse(String? raw) =>
      (raw ?? '').trim() == 'flow' ? flow : agent;
}

/// 玉简绑定的工作流模板。`revision == null` 表示开跑时取最新版。
class JadeSlipFlowBinding {
  const JadeSlipFlowBinding({
    required this.scope,
    required this.name,
    this.revision,
    this.inputs = const {},
    this.bindings = const {},
    this.inputFrom = const {},
  });

  /// `lib` 或 `group:<gid>`。
  final String scope;
  final String name;
  final int? revision;

  /// 预设输入（input name -> 值）。空值留给开跑表单补。
  final Map<String, String> inputs;

  /// 角色绑定（role -> agentId），可部分预填。
  final Map<String, String> bindings;

  /// 某个 input 的值来源：`manual`（用户填）或 `slip`（玉简字段自动映射）。
  final Map<String, String> inputFrom;

  bool get isEmpty => name.trim().isEmpty;

  JadeSlipFlowBinding copyWith({
    String? scope,
    String? name,
    int? revision,
    bool clearRevision = false,
    Map<String, String>? inputs,
    Map<String, String>? bindings,
    Map<String, String>? inputFrom,
  }) =>
      JadeSlipFlowBinding(
        scope: scope ?? this.scope,
        name: name ?? this.name,
        revision: clearRevision ? null : (revision ?? this.revision),
        inputs: inputs ?? this.inputs,
        bindings: bindings ?? this.bindings,
        inputFrom: inputFrom ?? this.inputFrom,
      );

  Map<String, dynamic> toJson() => {
        'scope': scope,
        'name': name,
        if (revision != null) 'revision': revision,
        if (inputs.isNotEmpty) 'inputs': inputs,
        if (bindings.isNotEmpty) 'bindings': bindings,
        if (inputFrom.isNotEmpty) 'input_from': inputFrom,
      };

  factory JadeSlipFlowBinding.fromJson(Map<String, dynamic> json) =>
      JadeSlipFlowBinding(
        scope: (json['scope'] as String? ?? '').trim(),
        name: (json['name'] as String? ?? '').trim(),
        revision: json['revision'] is num
            ? (json['revision'] as num).toInt()
            : int.tryParse(json['revision']?.toString() ?? ''),
        inputs: _stringMap(json['inputs']),
        bindings: _stringMap(json['bindings']),
        inputFrom: _stringMap(json['input_from']),
      );
}

/// 玉简发起的一次工作流运行。同一模板可以跑多次，按 runId 去重。
class JadeSlipFlowRun {
  const JadeSlipFlowRun({
    required this.runId,
    this.startedAt = 0,
    this.status = '',
    this.hostId = '',
  });

  final String runId;
  final int startedAt;

  /// running / succeeded / failed / cancelled。
  final String status;
  final String hostId;

  bool get isTerminal =>
      status == 'succeeded' ||
      status == 'failed' ||
      status == 'cancelled';

  JadeSlipFlowRun copyWith({
    String? runId,
    int? startedAt,
    String? status,
    String? hostId,
  }) =>
      JadeSlipFlowRun(
        runId: runId ?? this.runId,
        startedAt: startedAt ?? this.startedAt,
        status: status ?? this.status,
        hostId: hostId ?? this.hostId,
      );

  Map<String, dynamic> toJson() => {
        'run_id': runId,
        if (startedAt != 0) 'started_at': startedAt,
        if (status.isNotEmpty) 'status': status,
        if (hostId.isNotEmpty) 'host_id': hostId,
      };

  factory JadeSlipFlowRun.fromJson(Map<String, dynamic> json) =>
      JadeSlipFlowRun(
        runId: (json['run_id'] as String? ?? '').trim(),
        startedAt: (json['started_at'] as num?)?.toInt() ?? 0,
        status: (json['status'] as String? ?? '').trim(),
        hostId: (json['host_id'] as String? ?? '').trim(),
      );
}

/// 玉简条目：储物袋里的待办/笔记，供用户记录、Agent 勾选执行。
///
/// 落盘：切到 v3 后是 `pouch://<pouch_id>/slip:<id>/slip.json`（一条玉简一个
/// scope，附件在 `slip:<id>/files/`）；过渡期仍是 `pouch://slips/<id>.json`。
/// 附件落在同分区 `<id>/files/`。
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
    this.sourceChannelId = '',
    this.events = const [],
    this.removedItemIds = const [],
    this.contractVersion = 1,
    this.decisions = const [],
    this.currentConclusion,
    this.executorKind = JadeSlipExecutorKind.agent,
    this.flowBinding,
    this.flowRuns = const [],
    this.flowStatus = '',
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

  /// 过程留言：用户在 App 里写、Agent 用 `shepaw slip comment` 追加。
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

  /// 第一次派发所在的会话。之后改派不覆盖。
  final String sourceChannelId;

  /// 指派、提交、退回、验收、证据。评论仍是自由过程记录。
  final List<JadeSlipEvent> events;

  /// 已删除的清单项 id。合并时用来避免把另一端已删的项加回来。
  final List<String> removedItemIds;

  /// 契约版本：人改目标/约束/完成标准或新增决定时 +1。
  final int contractVersion;

  /// 人拍板的决定，一等公民；agent 只能转述、不能自报 decidedBy。
  final List<JadeSlipDecision> decisions;

  /// 覆盖式「当前结论」；旧结论留在动态里，不再误导。
  final JadeSlipConclusion? currentConclusion;

  /// 执行者类型。旧玉简缺省 agent，行为与改动前完全一致。
  final JadeSlipExecutorKind executorKind;

  /// executorKind == flow 时绑定的模板。切回 agent 不清空，方便来回切换。
  final JadeSlipFlowBinding? flowBinding;

  /// 这条玉简发起过的运行，最近 N 条；按 runId 去重。
  final List<JadeSlipFlowRun> flowRuns;

  /// 主机回写的运行状态锁：`needs_review` / `blocked` / 空。
  ///
  /// 每次写玉简都会按清单项重算 status，光改 status 会被覆盖。
  /// 工作流终态没有对应清单项，用这个显式锁让「待验收 / 受阻」能留住；
  /// 人验收完（全部 accepted）会清掉它。
  final String flowStatus;

  bool get isFlowExecutor =>
      executorKind == JadeSlipExecutorKind.flow && flowBinding != null;

  /// 最近一次运行（按开跑时间），没有则 null。
  JadeSlipFlowRun? get latestFlowRun {
    JadeSlipFlowRun? latest;
    for (final run in flowRuns) {
      if (run.runId.isEmpty) continue;
      if (latest == null || run.startedAt >= latest.startedAt) latest = run;
    }
    return latest;
  }

  JadeSlipFlowRun? flowRunById(String runId) {
    for (final run in flowRuns) {
      if (run.runId == runId) return run;
    }
    return null;
  }

  /// 权威副本所在设备 = 主机（Noise 指纹）。
  ///
  /// 客户端本地只有读缓存，不是权威；服务端唯一那份在主机自己这个目录里。
  final String deviceId;
  final int createdAt;
  final int updatedAt;

  int get doneCount => items
      .where((e) =>
          e.state == JadeSlipItemState.accepted ||
          e.state == JadeSlipItemState.submitted)
      .length;

  int get submittedCount =>
      items.where((e) => e.state == JadeSlipItemState.submitted).length;

  /// 真正验收通过的项。已提交但仍等人验收的不算。
  int get acceptedCount =>
      items.where((e) => e.state == JadeSlipItemState.accepted).length;

  int get itemCount => items.length;

  int get cancelledCount =>
      items.where((e) => e.state == JadeSlipItemState.cancelled).length;

  int get maxSubmissionRev => items.fold(
        0,
        (max, item) =>
            item.submission != null && item.submission!.rev > max
                ? item.submission!.rev
                : max,
      );

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
    if (sourceChannelId.trim().isNotEmpty) return false;
    if (events.isNotEmpty) return false;
    if (decisions.isNotEmpty) return false;
    if (currentConclusion != null) return false;
    if (executorKind != JadeSlipExecutorKind.agent) return false;
    if (flowBinding != null) return false;
    if (flowRuns.isNotEmpty) return false;
    if (flowStatus.isNotEmpty) return false;
    if (contractVersion != 1) return false;
    if (priority != JadeSlipPriority.none) return false;
    if (status != JadeSlipStatus.open) return false;
    return true;
  }

  String get relPath => '$id.json';

  /// 玉简正文记录：`<id>.json`（不含附件 `<id>/files/…`）。
  static bool isRecordPath(String path) {
    return !path.contains('/') &&
        path.endsWith('.json') &&
        path.length > '.json'.length;
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
    String? sourceChannelId,
    List<JadeSlipEvent>? events,
    List<String>? removedItemIds,
    int? contractVersion,
    List<JadeSlipDecision>? decisions,
    JadeSlipConclusion? currentConclusion,
    bool clearConclusion = false,
    JadeSlipExecutorKind? executorKind,
    JadeSlipFlowBinding? flowBinding,
    bool clearFlowBinding = false,
    List<JadeSlipFlowRun>? flowRuns,
    String? flowStatus,
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
      sourceChannelId: sourceChannelId ?? this.sourceChannelId,
      events: events ?? this.events,
      removedItemIds: removedItemIds ?? this.removedItemIds,
      contractVersion: contractVersion ?? this.contractVersion,
      decisions: decisions ?? this.decisions,
      currentConclusion:
          clearConclusion ? null : (currentConclusion ?? this.currentConclusion),
      executorKind: executorKind ?? this.executorKind,
      flowBinding:
          clearFlowBinding ? null : (flowBinding ?? this.flowBinding),
      flowRuns: flowRuns ?? this.flowRuns,
      flowStatus: flowStatus ?? this.flowStatus,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 全部验收通过才是 done。只要还有一项被堵住，整简就是 blocked。
  /// 还有人要做的是 open / in_progress，都交上来了是 needs_review。
  JadeSlip withDerivedStatus({int? updatedAt}) {
    if (status == JadeSlipStatus.archived) {
      return updatedAt == null ? this : copyWith(updatedAt: updatedAt);
    }
    if (items.isEmpty) {
      // 没有清单项时 status 由人或工作流回写决定；验收完清掉状态锁。
      final clearLock = flowStatus.isNotEmpty &&
          (status == JadeSlipStatus.done || status == JadeSlipStatus.archived);
      return clearLock || updatedAt != null
          ? copyWith(
              flowStatus: clearLock ? '' : null,
              updatedAt: updatedAt,
            )
          : this;
    }
    final allSettled = items.every((e) =>
        e.state == JadeSlipItemState.accepted ||
        e.state == JadeSlipItemState.cancelled);
    final cancelledOk = items.every((e) =>
        e.state != JadeSlipItemState.cancelled ||
        e.cancelledReason.trim().isNotEmpty);
    if (allSettled && cancelledOk) {
      // 人验收完 → done，工作流的状态锁也随之失效。
      return copyWith(
        status: JadeSlipStatus.done,
        flowStatus: '',
        updatedAt: updatedAt,
      );
    }
    // 工作流终态没有对应清单项：按主机回写的状态锁，不让清单派生覆盖。
    final locked = flowStatus == 'needs_review' || flowStatus == 'blocked'
        ? JadeSlipStatus.parse(flowStatus)
        : null;
    if (locked != null) {
      return copyWith(status: locked, updatedAt: updatedAt);
    }
    final JadeSlipStatus next;
    if (items.any((e) => e.state == JadeSlipItemState.blocked)) {
      next = JadeSlipStatus.blocked;
    } else if (items.any((e) => e.state == JadeSlipItemState.open)) {
      next = items.any((e) => e.state != JadeSlipItemState.open)
          ? JadeSlipStatus.inProgress
          : JadeSlipStatus.open;
    } else if (items.any((e) => e.state == JadeSlipItemState.submitted)) {
      next = JadeSlipStatus.needsReview;
    } else if (items.any((e) => e.state == JadeSlipItemState.cancelled)) {
      next = JadeSlipStatus.inProgress;
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
    final events = <String, JadeSlipEvent>{};
    for (final event in [...older.events, ...newer.events]) {
      events.putIfAbsent(event.id, () => event);
    }
    final eventList = events.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    // 运行记录按 runId 并集：终态优先于 running，避免两端各写一半时丢记录
    // 或把已结束的运行退回「进行中」。
    final runs = <String, JadeSlipFlowRun>{};
    for (final run in [...older.flowRuns, ...newer.flowRuns]) {
      if (run.runId.isEmpty) continue;
      final prev = runs[run.runId];
      if (prev == null || !prev.isTerminal && run.isTerminal) {
        runs[run.runId] = run;
      } else if (prev.isTerminal == run.isTerminal &&
          run.startedAt >= prev.startedAt) {
        runs[run.runId] = run;
      }
    }
    final runList = runs.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return newer
        .copyWith(
          items: items.values.toList(),
          comments: comments.values.toList(),
          attachments: attachments.values.toList(),
          events: eventList,
          removedItemIds: removed.toList(),
          contractVersion: newer.contractVersion,
          decisions: newer.decisions,
          currentConclusion: newer.currentConclusion,
          flowRuns: runList,
          updatedAt: newer.updatedAt,
        )
        .withDerivedStatus(updatedAt: newer.updatedAt);
  }

  Map<String, dynamic> toJson() => {
        'kind': 'jade_slip',
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
        if (sourceChannelId.isNotEmpty) 'source_channel_id': sourceChannelId,
        if (events.isNotEmpty)
          'events': [for (final e in events) e.toJson()],
        if (removedItemIds.isNotEmpty) 'removed_items': removedItemIds,
        if (contractVersion != 1) 'contract_version': contractVersion,
        if (decisions.isNotEmpty)
          'decisions': [for (final d in decisions) d.toJson()],
        if (currentConclusion != null)
          'current_conclusion': currentConclusion!.toJson(),
        if (executorKind != JadeSlipExecutorKind.agent)
          'executor_kind': executorKind.wire,
        if (flowBinding != null) 'flow_binding': flowBinding!.toJson(),
        if (flowRuns.isNotEmpty)
          'flow_runs': [for (final r in flowRuns) r.toJson()],
        if (flowStatus.isNotEmpty) 'flow_status': flowStatus,
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
      sourceChannelId: (json['source_channel_id'] as String? ?? '').trim(),
      events: [
        for (final item in (json['events'] as List? ?? const []))
          if (item is Map)
            JadeSlipEvent.fromJson(item.cast<String, dynamic>()),
      ],
      removedItemIds: [
        for (final id in (json['removed_items'] as List? ?? const []))
          id.toString().trim(),
      ].where((id) => id.isNotEmpty).toList(),
      contractVersion: (json['contract_version'] as num?)?.toInt() ?? 1,
      decisions: [
        for (final raw in (json['decisions'] as List? ?? const []))
          if (raw is Map)
            JadeSlipDecision.fromJson(raw.cast<String, dynamic>()),
      ],
      currentConclusion: json['current_conclusion'] is Map
          ? JadeSlipConclusion.fromJson(
              (json['current_conclusion'] as Map).cast<String, dynamic>())
          : null,
      executorKind: JadeSlipExecutorKind.parse(
          json['executor_kind'] is String ? json['executor_kind'] as String : ''),
      flowBinding: json['flow_binding'] is Map
          ? JadeSlipFlowBinding.fromJson(
              (json['flow_binding'] as Map).cast<String, dynamic>())
          : null,
      flowRuns: _flowRunsFrom(json['flow_runs']),
      flowStatus: json['flow_status'] is String
          ? (json['flow_status'] as String).trim()
          : '',
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
  ///
  /// [attachmentUriOf] 按附件 id 给地址（v3 的 `pouch://<pouch>/slip:<id>/…`）；
  /// 模型本身不知道袋子 id，缺省时退回 v2 形式的 [JadeSlipAttachment.uri]。
  String toAgentPrompt({
    JadeSlipItem? focusItem,
    bool onlyOpenItems = false,
    Map<String, String>? attachmentUriOf,
  }) {
    final scoped = focusItem != null
        ? <JadeSlipItem>[focusItem]
        : onlyOpenItems
            ? openItems
            : items;
    final buf = StringBuffer(
      '玉简「$title」（id=$id），待办 ${openItems.length}/$itemCount 项。'
      '请 shepaw slip get --id $id 现读，不要依赖对话里的旧副本。',
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
        final uri = attachmentUriOf?[a.id];
        buf.writeln(
            '- ${a.name} (attachment=${a.id} uri=${uri ?? a.uri})');
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
      buf.writeln('comments: ${comments.length} 条，用 slip get 查看，不在这里展开');
    }
    buf
      ..writeln()
      ..writeln('contract_version: $contractVersion');
    if (isFlowExecutor) {
      final binding = flowBinding!;
      buf.writeln(
          'executor: flow ${binding.scope}/${binding.name}'
          '${binding.revision == null ? '' : '@${binding.revision}'}');
      final latest = latestFlowRun;
      if (latest != null) {
        buf.writeln('latest_flow_run: ${latest.runId} ${latest.status}');
      }
    }
    if (currentConclusion != null) {
      buf.writeln('current_conclusion: ${currentConclusion!.text}');
    }
    if (decisions.isNotEmpty) {
      buf.writeln('decisions:');
      for (final d in decisions) {
        buf.writeln('- ${d.text} (by ${d.decidedBy})');
      }
    }
    if (items.any((e) =>
        e.acceptance != null ||
        e.submission != null ||
        e.returnReason.isNotEmpty ||
        e.state == JadeSlipItemState.cancelled)) {
      buf.writeln('per-item contract:');
      for (final item in items) {
        final criteria = item.acceptance?.criteria.join('；') ?? '';
        final sub = item.submission;
        final parts = <String>[
          if (criteria.isNotEmpty) '验收标准=$criteria',
          if (sub != null) '提交 r${sub.rev}=${sub.summary}',
          if (item.returnReason.isNotEmpty) '退回原因=${item.returnReason}',
          if (item.state == JadeSlipItemState.cancelled)
            '已取消=${item.cancelledReason}',
        ];
        if (parts.isNotEmpty) {
          buf.writeln('- ${item.id}: ${parts.join(' / ')}');
        }
      }
    }
    buf
      ..writeln()
      ..writeln('人和 Agent、Agent 与 Agent 写回同一条玉简：')
      ..writeln('- shepaw slip get --id $id  （现读全文；写命令只返回摘要）')
      ..writeln(
          '- shepaw slip item --id $id --item <itemId> --done true  （提交，等验收）')
      ..writeln(
          '- shepaw slip report --id $id --items <itemId,itemId> --text "进度" [--evidence <uri>]  （一次汇报多项）')
      ..writeln(
          '- shepaw slip item --id $id --item <itemId> --assignee <agent_id>')
      ..writeln(
          '- shepaw slip item --id $id --item <itemId> --block --reason "..."')
      ..writeln(
          '- shepaw slip item --id $id --item <itemId> --evidence <store-uri>')
      ..writeln('- shepaw slip comment --id $id --item <itemId> --text "进度"')
      ..writeln(
          '- shepaw slip accept --id $id [--item <itemId>]  （人验收，Agent 不可用）')
      ..writeln(
          '- shepaw slip item --id $id --item <itemId> --return --reason "..."  （人退回）');
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
    this.returnReason = '',
    this.cancelledReason = '',
    this.evidence = const [],
    this.gaps = const [],
    this.acceptance,
    this.submission,
    this.updatedAt = 0,
  });

  final String id;
  final String text;
  final JadeSlipItemState state;

  /// 已勾选（已提交或已验收）。旧数据里的 `done: true` 读成 accepted。
  bool get done =>
      state == JadeSlipItemState.accepted ||
      state == JadeSlipItemState.submitted;

  final String assigneeAgentId;
  final String assigneeAgentName;
  final String actorId;
  final String actorName;

  /// Agent 提交这项时正在干活的会话。人可以从事项打开它。
  final String sessionId;

  /// 这项被拆成的子简。空表示还没有。
  final String childSlipId;
  final String blockedReason;

  /// 人退回这项时给的原因。跟 blockedReason 分开，界面上不再显示成「阻塞」。
  final String returnReason;
  final String cancelledReason;
  final List<JadeSlipEvidence> evidence;
  final List<JadeSlipGap> gaps;
  final JadeSlipAcceptance? acceptance;
  final JadeSlipSubmission? submission;
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
    String? returnReason,
    String? cancelledReason,
    List<JadeSlipEvidence>? evidence,
    List<JadeSlipGap>? gaps,
    JadeSlipAcceptance? acceptance,
    bool clearAcceptance = false,
    JadeSlipSubmission? submission,
    bool clearSubmission = false,
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
        returnReason: returnReason ?? this.returnReason,
        cancelledReason: cancelledReason ?? this.cancelledReason,
        evidence: evidence ?? this.evidence,
        gaps: gaps ?? this.gaps,
        acceptance:
            clearAcceptance ? null : (acceptance ?? this.acceptance),
        submission:
            clearSubmission ? null : (submission ?? this.submission),
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
        if (returnReason.isNotEmpty) 'return_reason': returnReason,
        if (cancelledReason.isNotEmpty) 'cancelled_reason': cancelledReason,
        if (evidence.isNotEmpty)
          'evidence': [for (final e in evidence) e.toJson()],
        if (gaps.isNotEmpty) 'gaps': [for (final g in gaps) g.toJson()],
        if (acceptance != null) 'acceptance': acceptance!.toJson(),
        if (submission != null) 'submission': submission!.toJson(),
        if (updatedAt > 0) 'updated_at': updatedAt,
      };

  factory JadeSlipItem.fromJson(Map<String, dynamic> json) {
    final rawEvidence = json['evidence'];
    final evidence = <JadeSlipEvidence>[];
    if (rawEvidence is List) {
      for (final raw in rawEvidence) {
        final parsed = JadeSlipEvidence.fromRaw(raw);
        if (parsed != null &&
            !evidence.any((e) => e.key == parsed.key)) {
          evidence.add(parsed);
        }
      }
    } else if (rawEvidence is String) {
      final parsed = JadeSlipEvidence.fromRaw(rawEvidence);
      if (parsed != null) evidence.add(parsed);
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
      returnReason: json['return_reason'] as String? ?? '',
      cancelledReason: json['cancelled_reason'] as String? ?? '',
      evidence: evidence,
      gaps: [
        for (final raw in (json['gaps'] as List? ?? const []))
          if (raw is Map) JadeSlipGap.fromJson(raw.cast<String, dynamic>()),
      ],
      acceptance: json['acceptance'] is Map
          ? JadeSlipAcceptance.fromJson(
              (json['acceptance'] as Map).cast<String, dynamic>())
          : null,
      submission: json['submission'] is Map
          ? JadeSlipSubmission.fromJson(
              (json['submission'] as Map).cast<String, dynamic>())
          : null,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  static String newId() => const Uuid().v4().replaceAll('-', '').substring(0, 8);
}

enum JadeSlipItemState {
  open,
  submitted,
  accepted,
  blocked,
  cancelled;

  String get wire => name;

  String get mark => switch (this) {
        open => ' ',
        submitted => '~',
        accepted => 'x',
        blocked => '!',
        cancelled => '-',
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
      case 'cancelled':
        return cancelled;
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
    this.itemIds = const [],
    this.kind = 'progress',
    this.supersedes = '',
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorName;

  /// 挂在某一项上。空表示整简留言。
  final String itemId;

  /// 一次汇报覆盖多项时的 id 列表（`slip report`）。旧记录只有 itemId。
  final List<String> itemIds;

  /// progress / decision / risk / note
  final String kind;

  /// 指向被本条取代的旧留言 id（迁移时用）。
  final String supersedes;
  final String text;
  final int createdAt;

  String get displayName {
    if (authorName.isNotEmpty) return authorName;
    if (authorId.length >= 16 && !authorId.contains(' ')) {
      return authorId.substring(0, 8);
    }
    return authorId;
  }

  JadeSlipComment copyWith({
    String? text,
    List<String>? itemIds,
    String? kind,
    String? supersedes,
  }) =>
      JadeSlipComment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        itemId: itemId,
        itemIds: itemIds ?? this.itemIds,
        kind: kind ?? this.kind,
        supersedes: supersedes ?? this.supersedes,
        text: text ?? this.text,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_id': authorId,
        'author_name': authorName,
        if (itemIds.length > 1)
          'item_ids': itemIds
        else if (itemId.isNotEmpty)
          'item_id': itemId,
        if (kind != 'progress') 'kind': kind,
        if (supersedes.isNotEmpty) 'supersedes': supersedes,
        'text': text,
        'created_at': createdAt,
      };

  factory JadeSlipComment.fromJson(Map<String, dynamic> json) {
    final ids = <String>[];
    final rawIds = json['item_ids'];
    if (rawIds is List) {
      for (final raw in rawIds) {
        final id = raw.toString().trim();
        if (id.isNotEmpty) ids.add(id);
      }
    }
    final single = (json['item_id'] as String? ?? '').trim();
    return JadeSlipComment(
      id: (json['id'] as String? ?? '').trim(),
      authorId: (json['author_id'] as String? ?? '').trim(),
      authorName: (json['author_name'] as String? ?? '').trim(),
      itemId: single.isNotEmpty ? single : (ids.isNotEmpty ? ids.first : ''),
      itemIds: ids,
      kind: json['kind'] as String? ?? 'progress',
      supersedes: (json['supersedes'] as String? ?? '').trim(),
      text: json['text'] as String? ?? '',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  static String newId() => JadeSlipItem.newId();
}

/// 玉简上的一次状态变更。谁做的、对哪一项、发生了什么。
class JadeSlipEvent {
  const JadeSlipEvent({
    required this.id,
    required this.kind,
    this.actorId = '',
    this.actorName = '',
    this.itemId = '',
    required this.text,
    required this.createdAt,
  });

  final String id;

  /// submitted / accepted / returned / assigned / evidence。
  final String kind;
  final String actorId;
  final String actorName;
  final String itemId;
  final String text;
  final int createdAt;

  String get displayName {
    if (actorName.isNotEmpty) return actorName;
    if (actorId.length >= 16 && !actorId.contains(' ')) {
      return actorId.substring(0, 8);
    }
    return actorId;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (actorId.isNotEmpty) 'actor_id': actorId,
        if (actorName.isNotEmpty) 'actor_name': actorName,
        if (itemId.isNotEmpty) 'item_id': itemId,
        'text': text,
        'created_at': createdAt,
      };

  factory JadeSlipEvent.fromJson(Map<String, dynamic> json) => JadeSlipEvent(
        id: (json['id'] as String? ?? '').trim(),
        kind: (json['kind'] as String? ?? '').trim(),
        actorId: (json['actor_id'] as String? ?? '').trim(),
        actorName: (json['actor_name'] as String? ?? '').trim(),
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

  /// `slips` 分区内相对路径，如 `<id>/files/<attId>-name.pdf`。
  final String path;
  final int sizeBytes;

  /// 地址不带设备段（docs/pouch_uri_no_device_decision.md）。
  String get uri => storeUriWithRef(StoreSpace.slips, path);

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


/// 结构化证据：兼容旧记录里的裸 URI 字符串。
class JadeSlipEvidence {
  const JadeSlipEvidence({
    required this.uri,
    this.version,
    this.hash,
    this.size,
    this.mtimeMs,
    this.label,
    this.attachedAt,
  });

  final String uri;
  final int? version;
  final String? hash;
  final int? size;
  final int? mtimeMs;
  final String? label;
  final int? attachedAt;

  bool get isLegacy => version == null;
  String get key => '$uri#${version ?? 0}';

  String get displayName {
    if (label != null && label!.isNotEmpty) return label!;
    try {
      return Uri.decodeComponent(Uri.parse(uri).pathSegments.last);
    } catch (_) {
      return uri;
    }
  }

  String get versionLabel => version == null ? '' : ' · v$version';

  /// legacy 记录原样输出字符串，不把它改写成对象。
  Object toJson() {
    if (isLegacy) return uri;
    return {
      'uri': uri,
      if (version != null) 'version': version,
      if (hash != null) 'hash': hash,
      if (size != null) 'size': size,
      if (mtimeMs != null) 'mtime_ms': mtimeMs,
      if (label != null) 'label': label,
      if (attachedAt != null) 'attached_at': attachedAt,
    };
  }

  static JadeSlipEvidence? fromRaw(Object? raw) {
    if (raw is String) {
      final uri = raw.trim();
      return uri.isEmpty ? null : JadeSlipEvidence(uri: uri);
    }
    if (raw is Map) {
      final json = raw.cast<String, dynamic>();
      final uri = (json['uri'] as String? ?? '').trim();
      if (uri.isEmpty) return null;
      return JadeSlipEvidence(
        uri: uri,
        version: (json['version'] as num?)?.toInt(),
        hash: json['hash'] as String?,
        size: (json['size'] as num?)?.toInt(),
        mtimeMs: (json['mtime_ms'] as num?)?.toInt(),
        label: json['label'] as String?,
        attachedAt: (json['attached_at'] as num?)?.toInt(),
      );
    }
    return null;
  }
}

class JadeSlipAcceptance {
  const JadeSlipAcceptance({
    this.criteria = const [],
    this.verify = const [],
    this.confirmedBy = '',
    this.confirmedAt = 0,
  });

  final List<String> criteria;
  final List<String> verify;
  final String confirmedBy;
  final int confirmedAt;

  bool get isConfirmed => confirmedBy.isNotEmpty;

  JadeSlipAcceptance copyWith({
    List<String>? criteria,
    List<String>? verify,
    String? confirmedBy,
    int? confirmedAt,
  }) =>
      JadeSlipAcceptance(
        criteria: criteria ?? this.criteria,
        verify: verify ?? this.verify,
        confirmedBy: confirmedBy ?? this.confirmedBy,
        confirmedAt: confirmedAt ?? this.confirmedAt,
      );

  Map<String, dynamic> toJson() => {
        'criteria': criteria,
        'verify': verify,
        if (confirmedBy.isNotEmpty) 'confirmed_by': confirmedBy,
        if (confirmedAt > 0) 'confirmed_at': confirmedAt,
      };

  factory JadeSlipAcceptance.fromJson(Map<String, dynamic> json) =>
      JadeSlipAcceptance(
        criteria: _stringList(json['criteria']),
        verify: _stringList(json['verify']),
        confirmedBy: json['confirmed_by'] as String? ?? '',
        confirmedAt: (json['confirmed_at'] as num?)?.toInt() ?? 0,
      );
}

class JadeSlipSubmission {
  const JadeSlipSubmission({
    required this.rev,
    required this.summary,
    this.changed = const [],
    this.verify = const [],
    this.gaps = const [],
    this.codeRefs = const [],
    this.evidence = const [],
    this.submittedBy = '',
    this.sessionId = '',
    this.submittedAt = 0,
    this.supersedesRev,
  });

  final int rev;
  final String summary;
  final List<String> changed;
  final List<String> verify;
  final List<String> gaps;
  final List<String> codeRefs;
  final List<JadeSlipEvidence> evidence;
  final String submittedBy;
  final String sessionId;
  final int submittedAt;
  final int? supersedesRev;

  Map<String, dynamic> toJson() => {
        'rev': rev,
        'summary': summary,
        'changed': changed,
        'verify': verify,
        'gaps': gaps,
        'code_refs': codeRefs,
        if (evidence.isNotEmpty)
          'evidence': [for (final e in evidence) e.toJson()],
        if (submittedBy.isNotEmpty) 'submitted_by': submittedBy,
        if (sessionId.isNotEmpty) 'session_id': sessionId,
        if (submittedAt > 0) 'submitted_at': submittedAt,
        if (supersedesRev != null) 'supersedes_rev': supersedesRev,
      };

  factory JadeSlipSubmission.fromJson(Map<String, dynamic> json) =>
      JadeSlipSubmission(
        rev: (json['rev'] as num?)?.toInt() ?? 1,
        summary: json['summary'] as String? ?? '',
        changed: _stringList(json['changed']),
        verify: _stringList(json['verify']),
        gaps: _stringList(json['gaps']),
        codeRefs: _stringList(json['code_refs']),
        evidence: [
          for (final raw in (json['evidence'] as List? ?? const []))
            if (JadeSlipEvidence.fromRaw(raw) != null)
              JadeSlipEvidence.fromRaw(raw)!,
        ],
        submittedBy: json['submitted_by'] as String? ?? '',
        sessionId: json['session_id'] as String? ?? '',
        submittedAt: (json['submitted_at'] as num?)?.toInt() ?? 0,
        supersedesRev: (json['supersedes_rev'] as num?)?.toInt(),
      );
}

class JadeSlipGap {
  const JadeSlipGap({
    required this.id,
    required this.text,
    this.childSlipId = '',
  });

  final String id;
  final String text;
  final String childSlipId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (childSlipId.isNotEmpty) 'child_slip_id': childSlipId,
      };

  factory JadeSlipGap.fromJson(Map<String, dynamic> json) => JadeSlipGap(
        id: (json['id'] as String? ?? '').trim(),
        text: json['text'] as String? ?? '',
        childSlipId: (json['child_slip_id'] as String? ?? '').trim(),
      );
}

class JadeSlipDecision {
  const JadeSlipDecision({
    required this.id,
    required this.text,
    this.decidedBy = '',
    this.decidedAt = 0,
    this.sourceChannelId = '',
    this.itemIds = const [],
    this.supersedes = '',
  });

  final String id;
  final String text;
  final String decidedBy;
  final int decidedAt;
  final String sourceChannelId;
  final List<String> itemIds;
  final String supersedes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (decidedBy.isNotEmpty) 'decided_by': decidedBy,
        if (decidedAt > 0) 'decided_at': decidedAt,
        if (sourceChannelId.isNotEmpty)
          'source_channel_id': sourceChannelId,
        if (itemIds.isNotEmpty) 'item_ids': itemIds,
        if (supersedes.isNotEmpty) 'supersedes': supersedes,
      };

  factory JadeSlipDecision.fromJson(Map<String, dynamic> json) =>
      JadeSlipDecision(
        id: (json['id'] as String? ?? '').trim(),
        text: json['text'] as String? ?? '',
        decidedBy: json['decided_by'] as String? ?? '',
        decidedAt: (json['decided_at'] as num?)?.toInt() ?? 0,
        sourceChannelId: json['source_channel_id'] as String? ?? '',
        itemIds: _stringList(json['item_ids']),
        supersedes: (json['supersedes'] as String? ?? '').trim(),
      );
}

class JadeSlipConclusion {
  const JadeSlipConclusion({
    required this.text,
    this.by = '',
    this.at = 0,
    this.evidence = const [],
    this.submissionRev,
  });

  final String text;
  final String by;
  final int at;
  final List<String> evidence;
  final int? submissionRev;

  Map<String, dynamic> toJson() => {
        'text': text,
        if (by.isNotEmpty) 'by': by,
        if (at > 0) 'at': at,
        if (evidence.isNotEmpty) 'evidence': evidence,
        if (submissionRev != null) 'submission_rev': submissionRev,
      };

  factory JadeSlipConclusion.fromJson(Map<String, dynamic> json) =>
      JadeSlipConclusion(
        text: json['text'] as String? ?? '',
        by: json['by'] as String? ?? '',
        at: (json['at'] as num?)?.toInt() ?? 0,
        evidence: _stringList(json['evidence']),
        submissionRev: (json['submission_rev'] as num?)?.toInt(),
      );
}

List<String> _stringList(Object? raw) => [
      for (final value in (raw as List? ?? const []))
        if (value.toString().trim().isNotEmpty) value.toString().trim(),
    ];

/// 宽容解析 string->string 映射：类型不对、键为空、值为 null 都不该让整条
/// 玉简读不出来（旧 App / 手工改坏的记录）。
Map<String, String> _stringMap(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, String>{};
  raw.forEach((key, value) {
    final name = key.toString().trim();
    if (name.isNotEmpty) out[name] = value?.toString() ?? '';
  });
  return out;
}

List<JadeSlipFlowRun> _flowRunsFrom(Object? raw) {
  if (raw is! List) return const [];
  final out = <JadeSlipFlowRun>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final run = JadeSlipFlowRun.fromJson(item.cast<String, dynamic>());
    if (run.runId.isNotEmpty) out.add(run);
  }
  return out;
}
