import '../group/group_event.dart';
import 'event_envelope.dart';
import 'event_scope.dart';

/// Maps canonical [GroupEvent] → EventBus envelope (projection only).
class GroupEventAdapter {
  GroupEventAdapter._();

  static String typeFor(GroupEventType type) {
    switch (type) {
      case GroupEventType.memberJoined:
        return 'chat.group.member.joined';
      case GroupEventType.memberLeft:
        return 'chat.group.member.left';
      case GroupEventType.workflowStageStarted:
        return 'chat.group.workflow.stage.started';
      case GroupEventType.stepCompleted:
        return 'chat.group.step.completed';
      case GroupEventType.stepFailed:
        return 'chat.group.step.failed';
      case GroupEventType.stepSkipped:
        return 'chat.group.step.skipped';
      case GroupEventType.workflowCompleted:
        return 'chat.group.workflow.completed';
      case GroupEventType.workflowFailed:
        return 'chat.group.workflow.failed';
      case GroupEventType.loopRoundCompleted:
        return 'chat.group.loop.round.completed';
      case GroupEventType.memberPending:
        return 'chat.group.member.pending';
      case GroupEventType.memberStalled:
        return 'chat.group.member.stalled';
    }
  }

  static EventEnvelope toEnvelope(GroupEvent event) {
    return EventEnvelope(
      id: event.id,
      type: typeFor(event.type),
      source: 'system:chat.group',
      // poll_only 审计用途；orchestrationId 不是 RPC correlation（见 EVENT_DECISIONS R7）。
      correlationId: null,
      seq: 0, // assigned by EventBus on emit
      at: event.createdAt,
      payload: {
        'summary': event.summary.isNotEmpty
            ? event.summary
            : event.type.name,
        'group_event': _groupEventJson(event),
        if (event.stageIndex != null) 'stage_index': event.stageIndex,
        if (event.stepIndex != null) 'step_index': event.stepIndex,
        if (event.round != null) 'round': event.round,
        if (event.agentId != null) 'agent_id': event.agentId,
        if (event.agentName != null) 'agent_name': event.agentName,
        ...event.payload,
      },
      scope: EventScope(
        channelId: event.channelId,
        agentId: event.agentId,
      ),
    );
  }

  static Map<String, dynamic> _groupEventJson(GroupEvent event) => {
        'id': event.id,
        'type': event.type.name,
        'channel_id': event.channelId,
        if (event.stageIndex != null) 'stage': event.stageIndex,
        if (event.stepIndex != null) 'step': event.stepIndex,
        if (event.round != null) 'round': event.round,
        if (event.agentId != null) 'agent_id': event.agentId,
        if (event.agentName != null) 'agent_name': event.agentName,
        'summary': event.summary,
        'payload': event.payload,
        'created_at': event.createdAt.toIso8601String(),
        if (event.orchestrationId != null)
          'orchestration_id': event.orchestrationId,
      };
}
