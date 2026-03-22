/// ACP Server 消息模型
/// 定义 Agent → Hub 的消息格式
library;

import 'acp_protocol.dart';

// Re-export ACPError and ACPErrorCode from the unified definition
export 'acp_protocol.dart' show ACPError, ACPErrorCode;

/// ACP 请求类型
enum ACPRequestType {
  /// 发起聊天（需要用户同意）
  initiateChat,

  /// 获取 Agent 列表
  getAgentList,

  /// 获取 Agent 能力
  getAgentCapabilities,

  /// 获取 Hub 信息
  getHubInfo,

  /// 订阅 Channel 消息
  subscribeChannel,

  /// 取消订阅 Channel 消息
  unsubscribeChannel,

  /// 发送文件到 Hub
  sendFile,

  /// 获取会话列表
  getSessions,

  /// 获取会话消息
  getSessionMessages,

  /// 获取 UI 组件模板
  getUIComponentTemplates,

  /// 未知类型
  unknown,
}

/// ACP Server 请求
class ACPServerRequest {
  /// JSON-RPC 版本
  final String jsonrpc;

  /// 请求 ID
  final String id;

  /// 方法名
  final String method;

  /// 参数
  final Map<String, dynamic>? params;

  /// 请求时间戳
  final DateTime timestamp;

  /// 来源 Agent ID
  final String? sourceAgentId;

  ACPServerRequest({
    required this.jsonrpc,
    required this.id,
    required this.method,
    this.params,
    DateTime? timestamp,
    this.sourceAgentId,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 从 JSON 创建
  factory ACPServerRequest.fromJson(Map<String, dynamic> json) {
    return ACPServerRequest(
      jsonrpc: json['jsonrpc'] ?? '2.0',
      id: json['id'].toString(),
      method: json['method'] ?? '',
      params: json['params'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
      sourceAgentId: json['source_agent_id'],
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      'method': method,
      if (params != null) 'params': params,
      'timestamp': timestamp.toIso8601String(),
      if (sourceAgentId != null) 'source_agent_id': sourceAgentId,
    };
  }

  /// 获取请求类型
  ACPRequestType get requestType {
    switch (method) {
      case ACPMethod.hubInitiateChat:
        return ACPRequestType.initiateChat;
      case ACPMethod.hubGetAgentList:
        return ACPRequestType.getAgentList;
      case ACPMethod.hubGetAgentCapabilities:
        return ACPRequestType.getAgentCapabilities;
      case ACPMethod.hubGetHubInfo:
        return ACPRequestType.getHubInfo;
      case ACPMethod.hubSubscribeChannel:
        return ACPRequestType.subscribeChannel;
      case ACPMethod.hubUnsubscribeChannel:
        return ACPRequestType.unsubscribeChannel;
      case ACPMethod.hubSendFile:
        return ACPRequestType.sendFile;
      case ACPMethod.hubGetSessions:
        return ACPRequestType.getSessions;
      case ACPMethod.hubGetSessionMessages:
        return ACPRequestType.getSessionMessages;
      case ACPMethod.hubGetUIComponentTemplates:
        return ACPRequestType.getUIComponentTemplates;
      default:
        return ACPRequestType.unknown;
    }
  }
}

/// ACP Server 响应
class ACPServerResponse {
  /// JSON-RPC 版本
  final String jsonrpc;

  /// 请求 ID
  final String id;

  /// 结果数据
  final dynamic result;

  /// 错误信息
  final ACPError? error;

  /// 响应时间戳
  final DateTime timestamp;

  ACPServerResponse({
    required this.jsonrpc,
    required this.id,
    this.result,
    this.error,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 成功响应
  factory ACPServerResponse.success({
    required String id,
    required dynamic result,
  }) {
    return ACPServerResponse(
      jsonrpc: '2.0',
      id: id,
      result: result,
    );
  }

  /// 错误响应
  factory ACPServerResponse.error({
    required String id,
    required int code,
    required String message,
    dynamic data,
  }) {
    return ACPServerResponse(
      jsonrpc: '2.0',
      id: id,
      error: ACPError(code: code, message: message, data: data),
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      if (result != null) 'result': result,
      if (error != null) 'error': error!.toJson(),
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// 从 JSON 创建
  factory ACPServerResponse.fromJson(Map<String, dynamic> json) {
    return ACPServerResponse(
      jsonrpc: json['jsonrpc'] ?? '2.0',
      id: json['id'].toString(),
      result: json['result'],
      error: json['error'] != null
          ? ACPError.fromJson(json['error'])
          : null,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
    );
  }
}

/// 聊天发起请求
class InitiateChatRequest {
  final String message;
  final String? targetUserId;
  final String? targetChannelId;
  final String priority;
  final bool requiresResponse;

  InitiateChatRequest({
    required this.message,
    this.targetUserId,
    this.targetChannelId,
    this.priority = 'normal',
    this.requiresResponse = false,
  });

  factory InitiateChatRequest.fromParams(Map<String, dynamic> params) {
    return InitiateChatRequest(
      message: params['message'] ?? '',
      targetUserId: params['target_user_id'],
      targetChannelId: params['target_channel_id'],
      priority: params['priority'] ?? 'normal',
      requiresResponse: params['requires_response'] ?? false,
    );
  }
}

/// Agent 能力信息
class AgentCapabilities {
  final String agentId;
  final String name;
  final String description;
  final List<String> capabilities;
  final List<String> tools;
  final bool isOnline;

  AgentCapabilities({
    required this.agentId,
    required this.name,
    required this.description,
    required this.capabilities,
    required this.tools,
    required this.isOnline,
  });

  Map<String, dynamic> toJson() {
    return {
      'agent_id': agentId,
      'name': name,
      'description': description,
      'capabilities': capabilities,
      'tools': tools,
      'is_online': isOnline,
    };
  }
}

/// Hub 信息
class HubInfo {
  final String version;
  final String name;
  final List<String> supportedProtocols;
  final int agentCount;
  final int channelCount;
  final int onlineUserCount;

  HubInfo({
    required this.version,
    required this.name,
    required this.supportedProtocols,
    required this.agentCount,
    required this.channelCount,
    required this.onlineUserCount,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'name': name,
      'supported_protocols': supportedProtocols,
      'agent_count': agentCount,
      'channel_count': channelCount,
      'online_user_count': onlineUserCount,
    };
  }
}

/// 发送文件请求
class SendFileRequest {
  final String url;
  final String filename;
  final String mimeType;
  final int? size;
  final String? targetChannelId;
  final String? targetUserId;

  SendFileRequest({
    required this.url,
    required this.filename,
    required this.mimeType,
    this.size,
    this.targetChannelId,
    this.targetUserId,
  });

  factory SendFileRequest.fromParams(Map<String, dynamic> params) {
    return SendFileRequest(
      url: params['url'] ?? '',
      filename: params['filename'] ?? '',
      mimeType: params['mime_type'] ?? 'application/octet-stream',
      size: params['size'] as int?,
      targetChannelId: params['target_channel_id'],
      targetUserId: params['target_user_id'],
    );
  }
}

/// 获取会话消息请求
class GetSessionMessagesRequest {
  final String sessionId;
  final int limit;

  GetSessionMessagesRequest({
    required this.sessionId,
    this.limit = 50,
  });

  factory GetSessionMessagesRequest.fromParams(Map<String, dynamic> params) {
    return GetSessionMessagesRequest(
      sessionId: params['session_id'] ?? '',
      limit: params['limit'] ?? 50,
    );
  }
}
