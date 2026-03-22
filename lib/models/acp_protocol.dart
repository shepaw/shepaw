/// ACP (Agent Communication Protocol) 协议实现
/// 基于 JSON-RPC 2.0，用于 App <-> Agent 双向 WebSocket 通信

import 'dart:convert';

/// ACP 请求
class ACPRequest {
  /// JSON-RPC 版本（固定为 2.0）
  final String jsonrpc = '2.0';

  /// 方法名称
  final String method;

  /// 请求参数
  final Map<String, dynamic>? params;

  /// 请求 ID（用于匹配响应）
  final dynamic id;

  ACPRequest({
    required this.method,
    this.params,
    required this.id,
  });

  factory ACPRequest.fromJson(Map<String, dynamic> json) {
    return ACPRequest(
      method: json['method'] ?? '',
      params: json['params'] as Map<String, dynamic>?,
      id: json['id'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'method': method,
      if (params != null) 'params': params,
      'id': id,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// ACP 响应
class ACPResponse {
  /// JSON-RPC 版本
  final String jsonrpc;

  /// 响应结果（成功时）
  final dynamic result;

  /// 错误信息（失败时）
  final ACPError? error;

  /// 请求 ID（与请求匹配）
  final dynamic id;

  ACPResponse({
    required this.jsonrpc,
    this.result,
    this.error,
    required this.id,
  });

  factory ACPResponse.fromJson(Map<String, dynamic> json) {
    return ACPResponse(
      jsonrpc: json['jsonrpc'] ?? '2.0',
      result: json['result'],
      error: json['error'] != null ? ACPError.fromJson(json['error']) : null,
      id: json['id'],
    );
  }

  factory ACPResponse.fromJsonString(String jsonString) {
    return ACPResponse.fromJson(jsonDecode(jsonString));
  }

  factory ACPResponse.success({required dynamic id, required dynamic result}) {
    return ACPResponse(jsonrpc: '2.0', id: id, result: result);
  }

  factory ACPResponse.error({
    required dynamic id,
    required int code,
    required String message,
    dynamic data,
  }) {
    return ACPResponse(
      jsonrpc: '2.0',
      id: id,
      error: ACPError(code: code, message: message, data: data),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      if (result != null) 'result': result,
      if (error != null) 'error': error!.toJson(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  /// 是否成功
  bool get isSuccess => error == null;

  /// 是否失败
  bool get isError => error != null;
}

/// ACP 错误
class ACPError {
  /// 错误代码
  final int code;

  /// 错误消息
  final String message;

  /// 额外数据
  final dynamic data;

  ACPError({
    required this.code,
    required this.message,
    this.data,
  });

  factory ACPError.fromJson(Map<String, dynamic> json) {
    return ACPError(
      code: json['code'] ?? -1,
      message: json['message'] ?? 'Unknown error',
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'message': message,
      if (data != null) 'data': data,
    };
  }

  @override
  String toString() => 'ACPError($code): $message';
}

/// ACP 通知（单向推送，无 id）
class ACPNotification {
  /// JSON-RPC 版本
  final String jsonrpc = '2.0';

  /// 方法名称
  final String method;

  /// 参数
  final Map<String, dynamic>? params;

  ACPNotification({
    required this.method,
    this.params,
  });

  factory ACPNotification.fromJson(Map<String, dynamic> json) {
    return ACPNotification(
      method: json['method'] ?? '',
      params: json['params'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'method': method,
      if (params != null) 'params': params,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// ACP 方法常量
class ACPMethod {
  // ==================== App -> Agent 请求 ====================

  /// 认证连接
  static const String authAuthenticate = 'auth.authenticate';

  /// 发送消息
  static const String agentChat = 'agent.chat';

  /// 取消任务
  static const String agentCancelTask = 'agent.cancelTask';

  /// 提交交互响应
  static const String agentSubmitResponse = 'agent.submitResponse';

  /// 消息回滚
  static const String agentRollback = 'agent.rollback';

  /// 获取 Agent 卡片
  static const String agentGetCard = 'agent.getCard';

  /// 心跳
  static const String ping = 'ping';

  // ==================== Agent -> App 通知 (UI 事件) ====================

  /// 流式文本内容
  static const String uiTextContent = 'ui.textContent';

  /// 操作按钮确认
  static const String uiActionConfirmation = 'ui.actionConfirmation';

  /// 单选
  static const String uiSingleSelect = 'ui.singleSelect';

  /// 多选
  static const String uiMultiSelect = 'ui.multiSelect';

  /// 文件上传请求
  static const String uiFileUpload = 'ui.fileUpload';

  /// 结构化表单
  static const String uiForm = 'ui.form';

  /// 文件/图片消息
  static const String uiFileMessage = 'ui.fileMessage';

  /// 折叠/元数据消息
  static const String uiMessageMetadata = 'ui.messageMetadata';

  /// 请求更多历史
  static const String uiRequestHistory = 'ui.requestHistory';

  // ==================== Agent -> App 通知 (任务生命周期) ====================

  /// 任务开始
  static const String taskStarted = 'task.started';

  /// 任务完成
  static const String taskCompleted = 'task.completed';

  /// 任务错误
  static const String taskError = 'task.error';

  // ==================== App -> Agent 通知 (群组事件) ====================

  /// 群组成员加入
  static const String groupMemberJoined = 'group.memberJoined';

  /// 群组成员离开
  static const String groupMemberLeft = 'group.memberLeft';

  // ==================== Agent -> App 请求 (获取 App 数据) ====================

  /// 获取会话列表
  static const String hubGetSessions = 'hub.getSessions';

  /// 获取会话消息
  static const String hubGetSessionMessages = 'hub.getSessionMessages';

  /// 获取 Agent 列表
  static const String hubGetAgentList = 'hub.getAgentList';

  /// 获取 Hub 信息
  static const String hubGetHubInfo = 'hub.getHubInfo';

  /// 发送文件
  static const String hubSendFile = 'hub.sendFile';

  /// Agent 发起聊天
  static const String hubInitiateChat = 'hub.initiateChat';

  /// 获取 Agent 能力
  static const String hubGetAgentCapabilities = 'hub.getAgentCapabilities';

  /// 订阅 Channel
  static const String hubSubscribeChannel = 'hub.subscribeChannel';

  /// 取消订阅 Channel
  static const String hubUnsubscribeChannel = 'hub.unsubscribeChannel';

  /// 获取 UI 组件模板
  static const String hubGetUIComponentTemplates = 'hub.getUIComponentTemplates';

  /// 获取附件内容
  static const String hubGetAttachmentContent = 'hub.getAttachmentContent';

  // ==================== File Transfer ====================

  /// Request file data via WebSocket binary transfer
  static const String agentRequestFileData = 'agent.requestFileData';

  /// File transfer started notification
  static const String fileTransferStart = 'file.transferStart';

  /// File transfer completed notification
  static const String fileTransferComplete = 'file.transferComplete';

  /// File transfer error notification
  static const String fileTransferError = 'file.transferError';

  // ==================== Legacy (保留兼容) ====================

  static const String chat = 'chat';
  static const String executeTask = 'executeTask';
  static const String streamResponse = 'streamResponse';
  static const String authenticate = 'authenticate';
  static const String getStatus = 'getStatus';
  static const String getTools = 'getTools';
  static const String cancelTask = 'cancelTask';
}

/// ACP 错误代码（统一定义）
class ACPErrorCode {
  // JSON-RPC 标准错误
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  // 应用级错误
  static const int authenticationFailed = -32000;
  static const int unauthorized = -32001;
  static const int permissionDenied = -32002;
  static const int notFound = -32003;
  static const int pendingApproval = -32004;
  static const int sessionNotFound = -32005;
  static const int taskFailed = -32006;
  static const int timeout = -32007;
  static const int taskCancelled = -32008;
}
