import 'dart:async';

// ---------------------------------------------------------------------------
// Events — sealed hierarchy for UI-bound side effects
//
// 这些事件由 [ChatController] 通过事件流发出，View 层订阅后执行对应的副作用
// （弹 SnackBar、导航、滚动等）。它们是纯数据类，与控制器内部状态无耦合，
// 因此独立到本文件；`chat_controller.dart` 通过 export 重新导出以保持兼容。
// ---------------------------------------------------------------------------

sealed class ChatEvent {}

class ShowSnackBarEvent extends ChatEvent {
  final String message;
  ShowSnackBarEvent(this.message);
}

class ShowErrorSnackBarEvent extends ChatEvent {
  final String message;
  ShowErrorSnackBarEvent(this.message);
}

class ShowRetrySnackBarEvent extends ChatEvent {
  final String message;
  final String retryLabel;
  final Map<String, String> interruptedInfo;
  ShowRetrySnackBarEvent(this.message, this.retryLabel, this.interruptedInfo);
}

/// 主动重连进度提示：发送消息时发现 Agent 不可达，进入指数退避重试循环，
/// 每次尝试前发此事件。UI 显示形如 "正在重连… (1/3)" 的顶部提示。
class ShowReconnectingSnackBarEvent extends ChatEvent {
  final int attempt;
  final int total;
  ShowReconnectingSnackBarEvent(this.attempt, this.total);
}

/// 主动重连结束（连上 or 最终失败）：UI 应隐藏 [ShowReconnectingSnackBarEvent]
/// 之前展示的持久提示。
class HideReconnectingSnackBarEvent extends ChatEvent {}

class NavigateToSessionEvent extends ChatEvent {
  final String channelId;
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final bool embedded;
  NavigateToSessionEvent({
    required this.channelId,
    this.agentId,
    this.agentName,
    this.agentAvatar,
    this.embedded = false,
  });
}

class ShowLoadingOverlayEvent extends ChatEvent {
  final String message;
  ShowLoadingOverlayEvent(this.message);
}

class DismissOverlayEvent extends ChatEvent {}

class RequestScrollToBottomEvent extends ChatEvent {
  final bool force;
  RequestScrollToBottomEvent({this.force = false});
}

class ShowHistoryRequestDialogEvent extends ChatEvent {
  final String reason;
  final Completer<bool> result;
  ShowHistoryRequestDialogEvent(this.reason) : result = Completer<bool>();
}

class ShowOsToolConfirmationEvent extends ChatEvent {
  final String toolName;
  final Map<String, dynamic> args;
  final dynamic risk;
  final Completer<bool> result;
  ShowOsToolConfirmationEvent(this.toolName, this.args, this.risk) : result = Completer<bool>();
}

class GroupInteractionRequestEvent extends ChatEvent {
  final String agentId;
  final String agentName;
  final String interactionType; // 'action_confirmation', 'single_select', 'multi_select', 'form', 'file_upload'
  final Map<String, dynamic> data;
  final String groupStreamingMessageId;
  final Completer<Map<String, dynamic>?> result;
  GroupInteractionRequestEvent({
    required this.agentId,
    required this.agentName,
    required this.interactionType,
    required this.data,
    required this.groupStreamingMessageId,
  }) : result = Completer<Map<String, dynamic>?>();
}

class CloseScreenEvent extends ChatEvent {}

class AgentInfoUpdatedEvent extends ChatEvent {
  final String? name;
  final String? avatar;
  AgentInfoUpdatedEvent(this.name, this.avatar);
}
