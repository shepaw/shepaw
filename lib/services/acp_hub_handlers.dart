/// ACP Hub Handlers
/// Shared hub.* request processing logic used by both ACPServerService
/// (WebSocket Server for inbound Agent connections) and ACPAgentConnection
/// (WebSocket Client for outbound Agent connections).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/acp_protocol.dart';
import '../models/acp_server_message.dart';
import '../models/channel.dart';
import 'permission_service.dart';
import 'local_api_service.dart';
import 'file_download_service.dart';
import 'local_database_service.dart';
import 'local_file_storage_service.dart';
import 'ui_component_registry.dart';
import 'logger_service.dart';
import 'package:uuid/uuid.dart';

/// Handles hub.* JSON-RPC requests from Agents.
///
/// This class encapsulates the business logic for responding to Agent requests
/// for App data (sessions, messages, agent lists, etc.). It is designed to be
/// shared between:
/// - [ACPServerService]: the WebSocket server that Agents connect to
/// - [ACPAgentConnection]: the WebSocket client that connects to Agents
class ACPHubHandlers {
  final PermissionService _permissionService;
  final LocalApiService _apiService;
  final FileDownloadService _fileDownloadService;
  final LocalDatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  ACPHubHandlers({
    required PermissionService permissionService,
    required LocalApiService apiService,
    FileDownloadService? fileDownloadService,
    LocalDatabaseService? databaseService,
  })  : _permissionService = permissionService,
        _apiService = apiService,
        _fileDownloadService = fileDownloadService ?? FileDownloadService(),
        _databaseService = databaseService ?? LocalDatabaseService();

  /// Route a hub.* request to the appropriate handler.
  /// Returns an [ACPResponse] that should be sent back to the Agent.
  Future<ACPResponse> handleRequest({
    required String method,
    required dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  }) async {
    try {
      switch (method) {
        case ACPMethod.hubInitiateChat:
          return await _handleInitiateChat(id, params, agentId, agentName);
        case ACPMethod.hubGetAgentList:
          return await _handleGetAgentList(id, params, agentId);
        case ACPMethod.hubGetAgentCapabilities:
          return await _handleGetAgentCapabilities(id, params);
        case ACPMethod.hubGetHubInfo:
          return await _handleGetHubInfo(id);
        case ACPMethod.hubSubscribeChannel:
          return ACPResponse.success(id: id, result: {'status': 'subscribed'});
        case ACPMethod.hubUnsubscribeChannel:
          return ACPResponse.success(id: id, result: {'status': 'unsubscribed'});
        case ACPMethod.hubSendFile:
          return await _handleSendFile(id, params, agentId, agentName);
        case ACPMethod.hubGetSessions:
          return await _handleGetSessions(id, params, agentId, agentName);
        case ACPMethod.hubGetSessionMessages:
          return await _handleGetSessionMessages(id, params, agentId, agentName);
        case ACPMethod.hubGetAttachmentContent:
          return await _handleGetAttachmentContent(id, params, agentId, agentName);
        case ACPMethod.hubGetUIComponentTemplates:
          return _handleGetUIComponentTemplates(id);
        case ACPMethod.ping:
          return ACPResponse.success(id: id, result: {'pong': true});
        default:
          return ACPResponse.error(
            id: id,
            code: ACPErrorCode.methodNotFound,
            message: 'Method not found: $method',
          );
      }
    } catch (e) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.internalError,
        message: 'Internal error: $e',
      );
    }
  }

  Future<ACPResponse> _handleInitiateChat(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  ) async {
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.unauthorized,
        message: 'Agent not authenticated',
      );
    }

    final hasPermission = await _permissionService.checkPermission(
      agentId: agentId,
      permissionType: PermissionType.initiateChat,
    );

    if (!hasPermission) {
      final permissionRequest = await _permissionService.requestPermission(
        agentId: agentId,
        agentName: agentName ?? 'Unknown Agent',
        permissionType: PermissionType.initiateChat,
        reason: 'Agent wants to initiate a chat',
        metadata: params,
      );

      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.pendingApproval,
        message: 'Permission request pending user approval',
        data: {'permission_request_id': permissionRequest.id},
      );
    }

    final _ = InitiateChatRequest.fromParams(params ?? {});

    return ACPResponse.success(
      id: id,
      result: {
        'status': 'success',
        'message_id': DateTime.now().millisecondsSinceEpoch.toString(),
        'message': 'Chat initiated successfully',
      },
    );
  }

  Future<ACPResponse> _handleGetAgentList(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
  ) async {
    if (agentId != null) {
      final hasPermission = await _permissionService.checkPermission(
        agentId: agentId,
        permissionType: PermissionType.getAgentList,
      );

      if (!hasPermission) {
        return ACPResponse.error(
          id: id,
          code: ACPErrorCode.permissionDenied,
          message: 'Permission denied to access agent list',
        );
      }
    }

    final agents = await _apiService.getAgents();

    return ACPResponse.success(
      id: id,
      result: {
        'agents': agents.map((agent) => {
          'id': agent.id,
          'name': agent.name,
          'type': agent.type ?? agent.provider.type,
          'description': agent.description ?? agent.bio,
          'status': agent.status.state,
        }).toList(),
      },
    );
  }

  Future<ACPResponse> _handleGetAgentCapabilities(
    dynamic id,
    Map<String, dynamic>? params,
  ) async {
    final agentId = params?['agent_id'];
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.invalidParams,
        message: 'Missing agent_id parameter',
      );
    }

    return ACPResponse.success(
      id: id,
      result: {
        'agent_id': agentId,
        'capabilities': ['chat', 'task_execution', 'tool_calling'],
        'tools': ['bash', 'file_system', 'web_search'],
        'is_online': true,
      },
    );
  }

  Future<ACPResponse> _handleGetHubInfo(dynamic id) async {
    final agents = await _apiService.getAgents();

    return ACPResponse.success(
      id: id,
      result: {
        'version': '1.0.0',
        'name': 'Paw',
        'supported_protocols': ['ACP/1.0', 'A2A/1.0'],
        'agent_count': agents.length,
        'channel_count': 0,
        'online_user_count': 0,
      },
    );
  }

  Future<ACPResponse> _handleSendFile(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  ) async {
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.unauthorized,
        message: 'Agent not authenticated',
      );
    }

    final hasPermission = await _permissionService.checkPermission(
      agentId: agentId,
      permissionType: PermissionType.sendFile,
    );

    if (!hasPermission) {
      final permissionRequest = await _permissionService.requestPermission(
        agentId: agentId,
        agentName: agentName ?? 'Unknown Agent',
        permissionType: PermissionType.sendFile,
        reason: 'Agent wants to send a file',
        metadata: params,
      );

      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.pendingApproval,
        message: 'Permission request pending user approval',
        data: {'permission_request_id': permissionRequest.id},
      );
    }

    final sendFileReq = SendFileRequest.fromParams(params ?? {});

    if (sendFileReq.url.isEmpty) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.invalidParams,
        message: 'Missing url parameter',
      );
    }

    try {
      final result = await _fileDownloadService.downloadAndSave(
        sendFileReq.url,
        fileName: sendFileReq.filename.isNotEmpty ? sendFileReq.filename : null,
        mimeType: sendFileReq.mimeType,
        expectedSize: sendFileReq.size,
      );

      final channelId = sendFileReq.targetChannelId ?? '';
      final metadata = <String, dynamic>{
        'path': result.relativePath,
        'name': result.fileName,
        'type': result.mimeType,
        'size': result.fileSize,
        'source_url': sendFileReq.url,
      };

      final msgType = result.isImage ? 'image' : 'file';
      final messageId = _uuid.v4();

      await _databaseService.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: agentName ?? 'Agent',
        content: result.isImage
            ? '[Image: ${result.fileName}]'
            : '[File: ${result.fileName}]',
        messageType: msgType,
        metadata: metadata,
      );

      return ACPResponse.success(
        id: id,
        result: {
          'status': 'success',
          'message_id': messageId,
          'file': {
            'path': result.relativePath,
            'name': result.fileName,
            'size': result.fileSize,
            'mime_type': result.mimeType,
          },
        },
      );
    } catch (e) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.internalError,
        message: 'Failed to download file: $e',
      );
    }
  }

  Future<ACPResponse> _handleGetSessions(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  ) async {
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.unauthorized,
        message: 'Agent not authenticated',
      );
    }

    final result = await _permissionService.requestFreshPermissionAndWait(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      permissionType: PermissionType.getSessions,
      reason: 'Agent wants to access your session list',
    );

    await _recordAuditMessage(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      action: 'getSessions',
      approved: result.approved,
    );

    if (!result.approved) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.permissionDenied,
        message: 'User denied access to session list',
      );
    }

    final channels = await _databaseService.getAllChannels();

    return ACPResponse.success(
      id: id,
      result: {
        'sessions': channels.map((ch) => {
          'id': ch.id,
          'name': ch.name,
          'type': ch.type,
          'member_ids': ch.memberIds,
          'is_private': ch.isPrivate,
        }).toList(),
      },
    );
  }

  Future<ACPResponse> _handleGetSessionMessages(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  ) async {
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.unauthorized,
        message: 'Agent not authenticated',
      );
    }

    final sessionId = params?['session_id'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.invalidParams,
        message: 'Missing required parameter: session_id',
      );
    }

    final limit = params?['limit'] as int? ?? 50;

    final result = await _permissionService.requestFreshPermissionAndWait(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      permissionType: PermissionType.getSessionMessages,
      reason: 'Agent wants to read messages from session $sessionId',
      metadata: {'session_id': sessionId, 'limit': limit},
    );

    await _recordAuditMessage(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      action: 'getSessionMessages',
      approved: result.approved,
      extra: {'session_id': sessionId, 'limit': limit},
    );

    if (!result.approved) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.permissionDenied,
        message: 'User denied access to session messages',
      );
    }

    final messageMaps = await _databaseService.getChannelMessages(
      sessionId,
      limit: limit,
    );

    final messages = messageMaps.map((m) {
      final entry = <String, dynamic>{
        'id': m['id'],
        'sender_id': m['sender_id'],
        'sender_name': m['sender_name'],
        'content': m['content'],
        'message_type': m['message_type'],
        'created_at': m['created_at'],
      };
      // Add attachment metadata for non-text messages so agents can
      // identify attachments and retrieve content on demand.
      if (m['message_type'] != 'text' && m['metadata'] != null) {
        try {
          final metadata = jsonDecode(m['metadata'] as String);
          entry['attachment_info'] = <String, dynamic>{
            if (metadata['name'] != null) 'file_name': metadata['name'],
            if (metadata['size'] != null) 'file_size': metadata['size'],
            if (metadata['type'] != null) 'mime_type': metadata['type'],
          };
        } catch (_) {}
      }
      // Include structured mentions for text messages.
      if (m['metadata'] != null) {
        try {
          final meta = jsonDecode(m['metadata'] as String) as Map<String, dynamic>;
          final mentions = meta['mentions'] as List<dynamic>?;
          if (mentions != null && mentions.isNotEmpty) {
            entry['mentions'] = mentions;
          }
        } catch (_) {}
      }
      return entry;
    }).toList();

    return ACPResponse.success(
      id: id,
      result: {
        'session_id': sessionId,
        'messages': messages,
        'count': messages.length,
      },
    );
  }

  /// Handle hub.getAttachmentContent — returns the file content for an
  /// attachment message, encoded as base64.
  Future<ACPResponse> _handleGetAttachmentContent(
    dynamic id,
    Map<String, dynamic>? params,
    String? agentId,
    String? agentName,
  ) async {
    if (agentId == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.unauthorized,
        message: 'Agent not authenticated',
      );
    }

    final messageId = params?['message_id'] as String?;
    if (messageId == null || messageId.isEmpty) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.invalidParams,
        message: 'Missing required parameter: message_id',
      );
    }

    final result = await _permissionService.requestFreshPermissionAndWait(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      permissionType: PermissionType.getAttachmentContent,
      reason: 'Agent wants to read attachment content from message $messageId',
      metadata: {'message_id': messageId},
    );

    await _recordAuditMessage(
      agentId: agentId,
      agentName: agentName ?? 'Unknown Agent',
      action: 'getAttachmentContent',
      approved: result.approved,
      extra: {'message_id': messageId},
    );

    if (!result.approved) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.permissionDenied,
        message: 'User denied access to attachment content',
      );
    }

    final messageMap = await _databaseService.getMessageById(messageId);
    if (messageMap == null) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.notFound,
        message: 'Message not found: $messageId',
      );
    }

    final messageType = messageMap['message_type'] as String? ?? 'text';
    if (messageType == 'text' || messageType == 'system') {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.invalidParams,
        message: 'Message is not an attachment (type: $messageType)',
      );
    }

    // Parse metadata to get file path
    Map<String, dynamic>? metadata;
    try {
      if (messageMap['metadata'] != null) {
        metadata = jsonDecode(messageMap['metadata'] as String);
      }
    } catch (_) {}

    final relativePath = metadata?['path'] as String?;
    if (relativePath == null || relativePath.isEmpty) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.notFound,
        message: 'Attachment file path not found in message metadata',
      );
    }

    try {
      final storageService = LocalFileStorageService();
      final fullPath = await storageService.getFullPath(relativePath);
      final file = File(fullPath);
      if (!await file.exists()) {
        return ACPResponse.error(
          id: id,
          code: ACPErrorCode.notFound,
          message: 'Attachment file not found on disk',
        );
      }

      final bytes = await file.readAsBytes();
      final base64Content = base64Encode(bytes);

      return ACPResponse.success(
        id: id,
        result: {
          'message_id': messageId,
          'content': base64Content,
          'encoding': 'base64',
          'mime_type': metadata?['type'] ?? 'application/octet-stream',
          'file_name': metadata?['name'] ?? 'unknown',
          'file_size': bytes.length,
        },
      );
    } catch (e) {
      return ACPResponse.error(
        id: id,
        code: ACPErrorCode.internalError,
        message: 'Failed to read attachment file: $e',
      );
    }
  }

  /// Handle hub.getUIComponentTemplates — returns the centralized UI component
  /// definitions, schemas, and prompt templates.
  ACPResponse _handleGetUIComponentTemplates(dynamic id) {
    return ACPResponse.success(
      id: id,
      result: UIComponentRegistry.instance.toTemplatePayload(),
    );
  }

  /// Record an audit message to the chat history.
  /// Uses a dedicated audit channel per agent to avoid polluting chat sessions.
  Future<void> _recordAuditMessage({
    required String agentId,
    required String agentName,
    required String action,
    required bool approved,
    Map<String, dynamic>? extra,
  }) async {
    try {
      // Always use a dedicated audit channel to avoid mixing audit messages
      // with regular chat messages in different sessions.
      final channelId = 'system_audit_$agentId';
      final existingChannel = await _databaseService.getChannelById(channelId);

      if (existingChannel == null) {
        final channel = Channel.withMemberIds(
          id: channelId,
          name: 'Audit: $agentName',
          type: 'dm',
          memberIds: ['system', agentId],
          isPrivate: true,
        );
        await _databaseService.createChannel(channel, 'system');
      }

      final messageId = _uuid.v4();
      final now = DateTime.now();
      final metadata = {
        'permission_audit': {
          'agent_id': agentId,
          'agent_name': agentName,
          'action': action,
          'approved': approved,
          'timestamp': now.toIso8601String(),
          if (extra != null) ...extra,
        },
      };

      await _databaseService.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: approved
            ? 'Permission granted: $agentName requested $action'
            : 'Permission denied: $agentName requested $action',
        messageType: 'permission_audit',
        metadata: metadata,
      );
    } catch (e) {
      LoggerService().error('Failed to record audit message', tag: 'ACPHub', error: e);
    }
  }
}
