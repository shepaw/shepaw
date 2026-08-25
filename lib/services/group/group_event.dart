import 'package:uuid/uuid.dart';

/// Kinds of group events that agents (especially the group admin) may
/// perceive. Backed by the mutual-perception event system
/// (GroupEventPerceptionScheduler + GroupEventStore).
enum GroupEventType {
  /// 成员加入 / 离开（既有成员感知链路，经本系统泛化）。
  memberJoined,
  memberLeft,

  /// 工作流进入新阶段（被动上下文）。
  workflowStageStarted,

  /// 工作流节点成功完成。
  stepCompleted,

  /// 工作流节点失败。
  stepFailed,

  /// 工作流节点被跳过。
  stepSkipped,

  /// 整个工作流执行完毕 / 失败。
  workflowCompleted,
  workflowFailed,

  /// 编排循环一轮结束（loop 模式衔接，预留）。
  loopRoundCompleted,
}

/// One structured event in a group chat that agents can perceive.
///
/// - Passive events (step completions …) are recorded into the
///   [GroupEventStore] and injected into the next relevant member's context
///   bundle — zero extra LLM turns.
/// - Active-notify events (step failures, membership changes …) additionally
///   schedule a debounced admin perception turn.
class GroupEvent {
  final String id;
  final GroupEventType type;
  final String channelId;
  final int? stageIndex;
  final int? stepIndex;
  /// 编排循环轮次（loop 模式，M5）。
  final int? round;
  final String? agentId;
  final String? agentName;
  final String summary;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  GroupEvent({
    required this.id,
    required this.type,
    required this.channelId,
    this.stageIndex,
    this.stepIndex,
    this.round,
    this.agentId,
    this.agentName,
    this.summary = '',
    this.payload = const {},
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory GroupEvent.memberChange({
    required String channelId,
    required String memberId,
    required String memberName,
    required bool isJoin,
    String? id,
  }) {
    return GroupEvent(
      id: id ?? _newId(),
      type: isJoin ? GroupEventType.memberJoined : GroupEventType.memberLeft,
      channelId: channelId,
      agentId: memberId,
      agentName: memberName,
      summary: isJoin ? '成员 $memberName 加入群聊' : '成员 $memberName 离开群聊',
      payload: {'isJoin': isJoin},
    );
  }

  factory GroupEvent.stepCompleted({
    required String channelId,
    required int stageIndex,
    required int stepIndex,
    String? agentId,
    String? agentName,
    String summary = '',
    Map<String, dynamic> payload = const {},
    String? id,
  }) {
    return GroupEvent(
      id: id ?? _newId(),
      type: GroupEventType.stepCompleted,
      channelId: channelId,
      stageIndex: stageIndex,
      stepIndex: stepIndex,
      agentId: agentId,
      agentName: agentName,
      summary: summary,
      payload: payload,
    );
  }

  factory GroupEvent.stepFailed({
    required String channelId,
    required int stageIndex,
    required int stepIndex,
    String? agentId,
    String? agentName,
    String error = '',
    Map<String, dynamic> payload = const {},
    String? id,
  }) {
    return GroupEvent(
      id: id ?? _newId(),
      type: GroupEventType.stepFailed,
      channelId: channelId,
      stageIndex: stageIndex,
      stepIndex: stepIndex,
      agentId: agentId,
      agentName: agentName,
      summary: error.isEmpty ? '任务失败' : '任务失败：$error',
      payload: payload,
    );
  }

  /// 编排循环一轮完成（loop 模式，被动事件）：记录本轮派发的成员、失败
  /// 成员与管理员总结，供下一轮成员感知上一轮「谁做了什么、谁失败了」。
  factory GroupEvent.loopRoundCompleted({
    required String channelId,
    required int round,
    List<String>? delegatedAgentNames,
    List<String>? failedAgentNames,
    String summary = '',
    Map<String, dynamic> payload = const {},
    String? id,
  }) {
    return GroupEvent(
      id: id ?? _newId(),
      type: GroupEventType.loopRoundCompleted,
      channelId: channelId,
      round: round,
      agentName: null,
      summary: summary,
      payload: {
        'round': round,
        if (delegatedAgentNames != null && delegatedAgentNames.isNotEmpty)
          'delegated': delegatedAgentNames,
        if (failedAgentNames != null && failedAgentNames.isNotEmpty)
          'failed': failedAgentNames,
        ...payload,
      },
    );
  }

  /// 从工作空间持久化 payload 重建事件（崩溃恢复回放）。字段缺失/类型
  /// 不合法返回 null——回放是 best-effort，单条损坏不应拖垮整批恢复。
  static GroupEvent? fromPersisted(Map<String, dynamic> json, {String? channelId}) {
    final typeName = json['type'] as String?;
    if (typeName == null) return null;
    final type = GroupEventType.values.asNameMap()[typeName];
    if (type == null) return null;
    return GroupEvent(
      id: json['id'] as String? ?? _newId(),
      type: type,
      channelId: channelId ?? (json['channel_id'] as String? ?? ''),
      stageIndex: (json['stage'] as num?)?.toInt(),
      stepIndex: (json['step'] as num?)?.toInt(),
      round: (json['round'] as num?)?.toInt(),
      agentId: json['agent_id'] as String?,
      agentName: json['agent'] as String?,
      summary: json['summary'] as String? ?? '',
      payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      createdAt: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
    );
  }

  static String _newId() => const Uuid().v4();
}

/// Whether [e] is a workflow-step event — the subset injected into step
/// context bundles (membership/loop events are not step context).
bool isWorkflowStepEvent(GroupEvent e) =>
    e.type == GroupEventType.stepCompleted ||
    e.type == GroupEventType.stepFailed ||
    e.type == GroupEventType.stepSkipped ||
    e.type == GroupEventType.workflowStageStarted;

/// Render one event as a compact line for context injection / perception
/// prompts. Stage/step indexes are 0-based on the event but shown 1-based.
String renderEventLine(GroupEvent e) {
  final stage = e.stageIndex != null ? '阶段${e.stageIndex! + 1}' : '';
  final step = e.stepIndex != null ? '/步骤${e.stepIndex! + 1}' : '';
  final who = e.agentName != null ? ' · 成员${e.agentName}' : '';
  switch (e.type) {
    case GroupEventType.memberJoined:
      return '成员加入：${e.agentName}';
    case GroupEventType.memberLeft:
      return '成员离开：${e.agentName}';
    case GroupEventType.workflowStageStarted:
      return '工作流进入 $stage';
    case GroupEventType.stepCompleted:
      return '$stage$step$who · ✅ 完成 · ${e.summary}';
    case GroupEventType.stepFailed:
      return '$stage$step$who · ❌ 失败 · ${e.summary}';
    case GroupEventType.stepSkipped:
      return '$stage$step$who · ⏭ 已跳过';
    case GroupEventType.workflowCompleted:
      return '工作流已全部完成';
    case GroupEventType.workflowFailed:
      return '工作流执行失败：${e.summary}';
    case GroupEventType.loopRoundCompleted:
      final round = e.round != null ? '第${e.round}轮' : '';
      final delegated = (e.payload['delegated'] as List?)?.cast<String>();
      final failed = (e.payload['failed'] as List?)?.cast<String>();
      final parts = <String>['编排$round完成'];
      if (delegated != null && delegated.isNotEmpty) {
        parts.add('执行:${delegated.join('、')}');
      }
      if (failed != null && failed.isNotEmpty) {
        parts.add('失败:${failed.join('、')}');
      }
      if (e.summary.trim().isNotEmpty) {
        parts.add(e.summary.trim().replaceAll('\n', ' '));
      }
      return parts.join(' · ');
  }
}
