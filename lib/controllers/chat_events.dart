import 'dart:async';

import '../models/attachment_data.dart';
import '../models/message.dart';
import 'peer_approval_completer_resolver.dart';

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

  /// 目标会话是不是用户亲手挑的。清空 / 批量删除后由代码算出来的兜底会话
  /// 不是人工点选，不该覆盖「最近人工激活」指针（见
  /// `ChatNavigationService.openChannel` 的同名约束）。
  final bool manualActivation;
  NavigateToSessionEvent({
    required this.channelId,
    this.agentId,
    this.agentName,
    this.agentAvatar,
    this.embedded = false,
    this.manualActivation = true,
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

/// 回合内交过的提问答案没进引擎（主机已转 deferred）：界面补上本地化的
/// 气泡标题，调 [ChatController.resubmitLostFormAnswer] 续上。
class ResubmitLostFormAnswerEvent extends ChatEvent {
  final Message message;
  final String approvalId;
  final Map<String, dynamic> values;
  ResubmitLostFormAnswerEvent({
    required this.message,
    required this.approvalId,
    required this.values,
  });
}

class ShowHistoryRequestDialogEvent extends ChatEvent {
  final String reason;
  final Completer<bool> result;
  ShowHistoryRequestDialogEvent(this.reason) : result = Completer<bool>();
}

class GroupInteractionRequestEvent extends ChatEvent
    implements PendingInteractionLike {
  @override
  final String agentId;
  final String agentName;
  final String interactionType; // 'action_confirmation', 'single_select', 'multi_select', 'form', 'file_upload'
  @override
  final Map<String, dynamic> data;
  final String groupStreamingMessageId;
  @override
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

/// 发送失败后，把当前失败内容 + 待发送队列中的消息倒回输入框。
/// [content] 为按发送顺序合并后的文本（多条以换行分隔）。
/// [attachments] 为按发送顺序收集的全部附件（失败消息在前、队列消息在后），
/// 由 UI 侧根据 `pouch_uri` 重建为待发送附件，避免附件随失败丢失。
class RestoreQueueToComposerEvent extends ChatEvent {
  final String content;
  final List<AttachmentData> attachments;
  RestoreQueueToComposerEvent(this.content, {this.attachments = const []});
}
