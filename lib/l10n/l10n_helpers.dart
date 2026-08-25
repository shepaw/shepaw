import 'app_localizations.dart';
import '../models/agent_conversation_request.dart';
import '../models/agent_memory_entry.dart';
import '../models/remote_agent.dart';
import '../models/workflow_models.dart';

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
