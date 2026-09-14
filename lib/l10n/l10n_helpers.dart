import 'app_localizations.dart';
import '../models/agent_conversation_request.dart';
import '../models/agent_memory_entry.dart';
import '../models/remote_agent.dart';
import '../models/workflow_models.dart';
import '../services/event/event_delivery.dart';

/// Extension methods for RemoteAgent localization
/// Use these when displaying model data in UI contexts
extension RemoteAgentL10n on RemoteAgent {
  /// Get localized status text
  String localizedStatusText(AppLocalizations l10n) {
    switch (status) {
      case AgentStatus.online:
        return l10n.status_online;
      case AgentStatus.offline:
        return l10n.status_offline;
      case AgentStatus.error:
        return l10n.status_error;
    }
  }

  /// Get localized protocol name
  String localizedProtocolName(AppLocalizations l10n) {
    switch (protocol) {
      case ProtocolType.acp:
        return l10n.status_protocolAcp;
      case ProtocolType.custom:
        return l10n.status_protocolCustom;
      case ProtocolType.peer:
        return l10n.status_protocolPeer;
    }
  }

  /// Get localized connection type name (WebSocket / HTTP are not translated).
  String localizedConnectionTypeName(AppLocalizations l10n) {
    switch (connectionType) {
      case ConnectionType.websocket:
        return 'WebSocket';
      case ConnectionType.http:
        return 'HTTP';
    }
  }
}

/// Extension for formatting timestamps with localization
extension TimestampL10n on int {
  /// Format a millisecond timestamp as a relative time string
  String toRelativeTime(AppLocalizations l10n) {
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(this);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return l10n.agentDetail_justNow;
    } else if (diff.inMinutes < 60) {
      return l10n.agentDetail_minutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.agentDetail_hoursAgo(diff.inHours);
    } else if (diff.inDays < 7) {
      return l10n.common_daysAgo(diff.inDays);
    } else {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }
}

extension WorkflowStatusL10n on WorkflowStatus {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case WorkflowStatus.pendingApproval:
        return l10n.workflow_statusPendingApproval;
      case WorkflowStatus.running:
        return l10n.workflow_statusRunning;
      case WorkflowStatus.completed:
        return l10n.workflow_statusCompleted;
      case WorkflowStatus.failed:
        return l10n.workflow_statusFailed;
      case WorkflowStatus.cancelled:
        return l10n.workflow_statusCancelled;
    }
  }
}

extension StepExecutionStatusL10n on StepExecutionStatus {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case StepExecutionStatus.pending:
        return l10n.workflow_stepPending;
      case StepExecutionStatus.running:
        return l10n.workflow_stepRunning;
      case StepExecutionStatus.completed:
        return l10n.workflow_stepCompleted;
      case StepExecutionStatus.failed:
        return l10n.workflow_stepFailed;
      case StepExecutionStatus.skipped:
        return l10n.workflow_stepSkipped;
      case StepExecutionStatus.cancelled:
        return l10n.workflow_statusCancelled;
    }
  }
}

extension MemoryTypeL10n on MemoryType {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case MemoryType.conversation:
        return l10n.memory_typeConversation;
      case MemoryType.knowledge:
        return l10n.memory_typeKnowledge;
      case MemoryType.behavior:
        return l10n.memory_typeBehavior;
      case MemoryType.event:
        return l10n.memory_typeEvent;
      case MemoryType.emotion:
        return l10n.memory_typeEmotion;
    }
  }
}

extension AgentConversationRequestL10n on AgentConversationRequest {
  String localizedTimeAgo(AppLocalizations l10n) {
    return requestedAt.toRelativeTime(l10n);
  }
}

/// 事件类型 / 通配 pattern → 本地化展示名。
///
/// 只做渲染层名称化：`EventTypeDefinition.id` 等原始标识保持不变，调用方
/// 需要原始值时仍读原字段（tooltip / 次行）。
///
/// 1) 精确类型命中   → 类型名          ('peer.pairing.inbound' → 设备配对请求)
/// 2) 前缀通配 `ns.*` → 家族名 + ' · *' ('chat.group.*'        → 群聊编排 · *)
/// 3) 其余           → 原样返回        (`agent.<id>.*` 运行期才注册，必须兜底)
String localizeEventTypeLabel(AppLocalizations l10n, String pattern) {
  final exact = _eventTypeLabels(l10n)[pattern];
  if (exact != null) return exact;

  if (pattern.endsWith('.*')) {
    final namespace = pattern.substring(0, pattern.length - 2);
    final family = localizeEventFamilyLabel(l10n, namespace);
    if (family != null) return '$family · *';
  }
  return pattern;
}

/// 命名空间（如 `chat.group` / `peer`）→ 家族名；未收录时返回 null。
///
/// 先按全前缀命中（`chat.group` 与 `chat.message` 是两个家族），再退化到首段
/// （`peer.pairing` → `peer`），这样 `peer.pairing.*` 这类更深一层的通配也有名字。
String? localizeEventFamilyLabel(AppLocalizations l10n, String namespace) {
  final families = _eventFamilyLabels(l10n);
  return families[namespace] ?? families[namespace.split('.').first];
}

/// 投递档位名称化：poll_only / passive / active → 轮询 / 被动 / 主动。
extension EventDeliveryL10n on EventDelivery {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case EventDelivery.pollOnly:
        return l10n.event_deliveryPollOnly;
      case EventDelivery.passive:
        return l10n.event_deliveryPassive;
      case EventDelivery.active:
        return l10n.event_deliveryActive;
    }
  }
}

/// 线上档位值（`EventDelivery.wireValue`）→ 本地化名；无法识别时回退原文
/// （`null` / 空串返回 `null`，交由调用方决定是否省略）。
String? localizeEventDelivery(
  AppLocalizations l10n,
  String? wireValue,
) {
  if (wireValue == null || wireValue.isEmpty) return null;
  return EventDelivery.fromWire(wireValue)?.localizedLabel(l10n) ?? wireValue;
}

/// 已注册事件类型 id → 本地化名。运行期注册的 `agent.<id>.*` 不在表内，
/// 调用方需自行兜底（见 [localizeEventTypeLabel]）。
Map<String, String> _eventTypeLabels(AppLocalizations l10n) => {
      'peer.pairing.inbound': l10n.event_type_peerPairingInbound,
      'peer.pairing.completed': l10n.event_type_peerPairingCompleted,
      'peer.pairing.rejected': l10n.event_type_peerPairingRejected,
      'peer.connection.changed': l10n.event_type_peerConnectionChanged,
      'chat.group.member.joined': l10n.event_type_chatGroupMemberJoined,
      'chat.group.member.left': l10n.event_type_chatGroupMemberLeft,
      'chat.group.workflow.stage.started':
          l10n.event_type_chatGroupStageStarted,
      'chat.group.step.completed': l10n.event_type_chatGroupStepCompleted,
      'chat.group.step.failed': l10n.event_type_chatGroupStepFailed,
      'chat.group.step.skipped': l10n.event_type_chatGroupStepSkipped,
      'chat.group.workflow.completed':
          l10n.event_type_chatGroupWorkflowCompleted,
      'chat.group.workflow.failed': l10n.event_type_chatGroupWorkflowFailed,
      'chat.group.loop.round.completed':
          l10n.event_type_chatGroupLoopRoundCompleted,
      'chat.group.member.pending': l10n.event_type_chatGroupMemberPending,
      'chat.group.member.stalled': l10n.event_type_chatGroupMemberStalled,
      'chat.message.mention': l10n.event_type_chatMessageMention,
      'workflow.approval.pending': l10n.event_type_workflowApprovalPending,
      'workflow.approval.resolved': l10n.event_type_workflowApprovalResolved,
      'store.file.changed': l10n.event_type_storeFileChanged,
      'store.backup.completed': l10n.event_type_storeBackupCompleted,
      'store.backup.failed': l10n.event_type_storeBackupFailed,
      'system.app.lifecycle': l10n.event_type_systemAppLifecycle,
      'test.event.ping': l10n.event_type_testEventPing,
      'test.event.pong': l10n.event_type_testEventPong,
    };

/// 命名空间 → 家族名。键为 `pattern` 去掉尾部 `.*` 后的全前缀
/// （`chat.group.*` → `chat.group`）；单段键（`peer` / `store` …）覆盖
/// `peer.pairing.*` 这类更深一层的通配。
Map<String, String> _eventFamilyLabels(AppLocalizations l10n) => {
      'peer': l10n.event_family_peer,
      'chat.group': l10n.event_family_chatGroup,
      'chat.message': l10n.event_family_chatMessage,
      'workflow': l10n.event_family_workflow,
      'store': l10n.event_family_store,
      'system': l10n.event_family_system,
      'test': l10n.event_family_test,
      'agent': l10n.event_family_agent,
    };

/// Resolves known peer-approval action ids to localized button labels.
String localizePeerApprovalActionLabel(
  AppLocalizations l10n,
  String actionId,
  String fallbackLabel,
) {
  switch (actionId) {
    case 'allow':
      return l10n.peerApproval_allow;
    case 'deny':
      return l10n.peerApproval_deny;
    default:
      return fallbackLabel;
  }
}
