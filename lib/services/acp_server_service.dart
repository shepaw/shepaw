/// ACP Server 服务
/// 实现 WebSocket Server，接收 Agent 主动请求
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../models/acp_protocol.dart';
import '../models/acp_server_message.dart';
import '../models/remote_agent.dart';
import '../models/attachment_data.dart';
import '../models/channel.dart';
import 'permission_service.dart';
import 'local_api_service.dart';
import 'file_download_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';
import 'acp_hub_handlers.dart';
import 'chat_service.dart';

/// ACP Server 配置
class ACPServerConfig {
  final String host;
  final int port;
  final int heartbeatInterval;
  final bool enableTLS;
  final String? certPath;
  final String? keyPath;
  /// 连接 token（不为空时强制校验）
  final String? token;

  ACPServerConfig({
    this.host = '0.0.0.0',
    this.port = 18790,
    this.heartbeatInterval = 30,
    this.enableTLS = false,
    this.certPath,
    this.keyPath,
    this.token,
  });
}

/// ACP 客户端连接
class ACPClientConnection {
  final String id;
  final WebSocket socket;
  String? agentId;
  String? agentName;
  final DateTime connectedAt;
  DateTime lastActivityAt;
  final Set<String> subscribedChannels = {};

  ACPClientConnection({
    required this.id,
    required this.socket,
    this.agentId,
    this.agentName,
    DateTime? connectedAt,
    DateTime? lastActivityAt,
  })  : connectedAt = connectedAt ?? DateTime.now(),
        lastActivityAt = lastActivityAt ?? DateTime.now();

  void send(Map<String, dynamic> message) {
    socket.add(jsonEncode(message));
    lastActivityAt = DateTime.now();
  }

  void sendBinary(Uint8List data) {
    socket.add(data);
    lastActivityAt = DateTime.now();
  }

  void sendResponse(ACPServerResponse response) {
    send(response.toJson());
  }

  Future<void> close() async {
    await socket.close();
  }
}

/// ACP Server 服务
class ACPServerService {
  final ACPServerConfig config;
  final ACPHubHandlers _hubHandlers;
  final LocalDatabaseService? _databaseService;

  HttpServer? _server;
  final Map<String, ACPClientConnection> _connections = {};
  final StreamController<ACPServerRequest> _requestController =
      StreamController<ACPServerRequest>.broadcast();
  Timer? _heartbeatTimer;

  bool _isRunning = false;
  String? _startError; // 启动失败时的错误信息

  /// 当前有效 token（可热更新，不需要重启 server）
  /// 初始值来自 config.token，可通过 updateToken() 修改
  String? _activeToken;

  /// Called when an inbound agent connection disconnects.
  /// Provides the agentId (if known) so the caller can update status.
  void Function(String? agentId)? onAgentDisconnected;

  /// Called when an inbound agent sends a ui.fileMessage notification.
  /// Provides agentId, agentName, and the notification params.
  void Function(String agentId, String agentName, Map<String, dynamic> params)? onFileMessage;

  // ==================== File Transfer Callbacks ====================

  void Function(String agentId, String fileId, Uint8List chunk)? onFileChunk;
  void Function(String agentId, String fileId, int totalBytes)? onFileTransferComplete;
  void Function(String agentId, String fileId, String error)? onFileTransferError;

  /// Pending requests sent TO agents, keyed by request ID.
  final Map<String, Completer<Map<String, dynamic>>> _pendingServerRequests = {};
  int _serverRequestId = 0;

  /// file_id → 本地文件路径，供 agent.requestFileData 使用
  final Map<String, String> _pendingFileTransfers = {};

  ACPServerService({
    required this.config,
    required PermissionService permissionService,
    required LocalApiService apiService,
    FileDownloadService? fileDownloadService,
    LocalDatabaseService? databaseService,
  })  : _activeToken = config.token,
        _databaseService = databaseService,
        _hubHandlers = ACPHubHandlers(
          permissionService: permissionService,
          apiService: apiService,
          fileDownloadService: fileDownloadService,
          databaseService: databaseService,
        );

  bool get isRunning => _isRunning;
  /// 启动失败时的错误信息（null 表示正常）
  String? get startError => _startError;
  /// 当前有效 token
  String? get activeToken => _activeToken;
  int get connectionCount => _connections.length;
  Stream<ACPServerRequest> get requestStream => _requestController.stream;

  /// 热更新 token（无需重启 server，立即生效）
  void updateToken(String? newToken) {
    _activeToken = newToken;
  }

  Future<void> start() async {
    if (_isRunning) {
      throw StateError('ACP Server already running');
    }

    _startError = null;
    try {
      _server = await HttpServer.bind(config.host, config.port);
      _isRunning = true;

      LoggerService().info('ACP Server started on ${config.host}:${config.port}', tag: 'ACPServer');

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          _handleWebSocketUpgrade(request);
        } else {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write('WebSocket upgrade required')
            ..close();
        }
      });

      _startHeartbeat();
    } catch (e) {
      _isRunning = false;
      _startError = e.toString();
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    _heartbeatTimer?.cancel();

    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();

    await _server?.close();
    _server = null;

    LoggerService().info('ACP Server stopped', tag: 'ACPServer');
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    final queryParams = request.uri.queryParameters;
    // Prefer token from Authorization header (secure: not logged in server URLs).
    // Format: Authorization: Bearer <token>
    // Fall back to query param for backward compatibility (can be removed later).
    String? providedToken;
    final authHeader = request.headers.value('authorization');
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      providedToken = authHeader.substring(7);
    } else {
      providedToken = queryParams['token'];
    }
    // agentId is a routing hint, not a secret — keep it in the query string.
    final agentIdParam = queryParams['agentId'];

    if (agentIdParam != null && agentIdParam.isNotEmpty) {
      // Per-agent routing: validate token against the specific local agent
      if (_databaseService == null) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Server misconfiguration: database unavailable')
          ..close();
        return;
      }

      // Look up the agent from database
      RemoteAgent? agent;
      try {
        agent = await _databaseService!.getRemoteAgentById(agentIdParam);
      } catch (e) {
        LoggerService().warning('Failed to look up agent $agentIdParam: $e', tag: 'ACPServer');
      }

      if (agent == null) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized: agent not found')
          ..close();
        LoggerService().warning(
          'Rejected connection: agent $agentIdParam not found',
          tag: 'ACPServer',
        );
        return;
      }

      // Check if it's a local agent (has llm_provider in metadata)
      if (!agent.metadata.containsKey('llm_provider')) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized: agent is not a local agent')
          ..close();
        LoggerService().warning(
          'Rejected connection: agent $agentIdParam is not a local agent',
          tag: 'ACPServer',
        );
        return;
      }

      // Check allow_external_access flag
      if (agent.metadata['allow_external_access'] != true) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized: external access not enabled for this agent')
          ..close();
        LoggerService().warning(
          'Rejected connection: external access not enabled for agent $agentIdParam',
          tag: 'ACPServer',
        );
        return;
      }

      // Validate token
      if (providedToken != agent.token) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized: invalid token for agent')
          ..close();
        LoggerService().warning(
          'Rejected connection: invalid token for agent $agentIdParam',
          tag: 'ACPServer',
        );
        return;
      }

      // All checks passed — upgrade the connection and pre-populate agentId
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        final connectionId = DateTime.now().millisecondsSinceEpoch.toString();

        final connection = ACPClientConnection(
          id: connectionId,
          socket: socket,
          agentId: agentIdParam,
          agentName: agent.name,
        );

        _connections[connectionId] = connection;

        LoggerService().debug(
          'New ACP connection (local agent): $connectionId (agent: $agentIdParam)',
          tag: 'ACPServer',
        );

        socket.listen(
          (message) => _handleMessage(connection, message),
          onError: (error) => _handleError(connection, error),
          onDone: () => _handleDisconnect(connection),
        );
      } catch (e) {
        LoggerService().error('WebSocket upgrade failed', tag: 'ACPServer', error: e);
      }
      return;
    }

    // Legacy / remote agent path: check global token
    final expectedToken = _activeToken;
    if (expectedToken != null && expectedToken.isNotEmpty) {
      if (providedToken != expectedToken) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized: invalid or missing token')
          ..close();
        LoggerService().warning(
          'Rejected connection: invalid token from ${request.connectionInfo?.remoteAddress.address}',
          tag: 'ACPServer',
        );
        return;
      }
    }

    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final connectionId = DateTime.now().millisecondsSinceEpoch.toString();

      final connection = ACPClientConnection(
        id: connectionId,
        socket: socket,
      );

      _connections[connectionId] = connection;

      LoggerService().debug('New ACP connection: $connectionId', tag: 'ACPServer');

      socket.listen(
        (message) => _handleMessage(connection, message),
        onError: (error) => _handleError(connection, error),
        onDone: () => _handleDisconnect(connection),
      );
    } catch (e) {
      LoggerService().error('WebSocket upgrade failed', tag: 'ACPServer', error: e);
    }
  }

  Future<void> _handleMessage(
    ACPClientConnection connection,
    dynamic message,
  ) async {
    connection.lastActivityAt = DateTime.now();

    // Handle binary WebSocket frames (file transfer chunks)
    if (message is List<int>) {
      _handleBinaryFrame(connection, Uint8List.fromList(message));
      return;
    }

    try {
      final json = jsonDecode(message as String) as Map<String, dynamic>;

      // Extract agent identity from any message
      final sourceAgentId = json['source_agent_id'] as String?;
      if (connection.agentId == null && sourceAgentId != null) {
        connection.agentId = sourceAgentId;
      }

      final hasId = json.containsKey('id') && json['id'] != null;
      final hasMethod = json.containsKey('method') && json['method'] != null;

      if (hasMethod && !hasId) {
        // JSON-RPC Notification (no id) — e.g. ui.fileMessage, ui.textContent
        _handleNotification(connection, json);
      } else if (hasMethod && hasId) {
        // JSON-RPC Request (has id and method)
        final request = ACPServerRequest.fromJson(json);
        _requestController.add(request);

        // agent.chat is handled specially: route to local LLM agent and
        // stream the result back as ACP notifications.
        if (request.method == ACPMethod.agentChat) {
          _handleAgentChat(connection, request);
          return;
        }

        if (request.method == ACPMethod.agentRequestFileData) {
          _handleAgentRequestFileData(connection, request);
          return;
        }

        final response = await _hubHandlers.handleRequest(
          method: request.method,
          id: request.id,
          params: request.params,
          agentId: connection.agentId,
          agentName: connection.agentName,
        );

        connection.sendResponse(ACPServerResponse(
          jsonrpc: response.jsonrpc,
          id: response.id.toString(),
          result: response.result,
          error: response.error,
        ));
      } else if (hasId && !hasMethod) {
        // Response to a request we sent to the agent
        final id = json['id'].toString();
        final completer = _pendingServerRequests.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(json);
        }
      }
    } catch (e) {
      LoggerService().error('Failed to process message', tag: 'ACPServer', error: e);
      connection.sendResponse(
        ACPServerResponse.error(
          id: '0',
          code: ACPErrorCode.parseError,
          message: 'Failed to parse message: $e',
        ),
      );
    }
  }

  /// Route an incoming agent.chat request to the local LLM agent using the
  /// full ChatService execution path (multi-round tool calling, OS tools,
  /// skills, tool models, multimodal attachments) and stream the result back
  /// to the remote caller via ACP notifications.
  /// Also persists the conversation to a dedicated channel so it appears in
  /// the app's chat history.
  Future<void> _handleAgentChat(
    ACPClientConnection connection,
    ACPServerRequest request,
  ) async {
    final params = request.params ?? {};
    final taskId    = params['task_id']    as String? ?? request.id;
    final message   = params['message']    as String? ?? '';
    final sessionId = params['session_id'] as String? ?? taskId;
    final userId    = params['user_id']    as String? ?? connection.agentId ?? 'remote';
    final userName  = connection.agentName ?? userId;

    // Deserialise ACP attachments back into AttachmentData objects
    final rawAttachments = params['attachments'] as List?;
    List<AttachmentData>? attachments;
    if (rawAttachments != null && rawAttachments.isNotEmpty) {
      try {
        attachments = rawAttachments
            .cast<Map<String, dynamic>>()
            .map((a) => AttachmentData(
                  fileName: a['file_name'] as String? ?? 'file',
                  mimeType: a['mime_type'] as String? ?? 'application/octet-stream',
                  sizeBytes: a['size'] as int? ?? 0,
                  bytes: base64Decode(a['data'] as String? ?? ''),
                  semanticType: a['type'] as String? ?? 'file',
                  extraMetadata: a['extra'] as Map<String, dynamic>?,
                ))
            .toList();
      } catch (e) {
        LoggerService().warning('Failed to deserialise attachments: $e', tag: 'ACPServer');
      }
    }

    final targetAgentId = connection.agentId;
    if (targetAgentId == null) {
      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.taskError,
        'params': {'task_id': taskId, 'message': 'Agent ID not established'},
      });
      return;
    }

    // Look up the local agent from the database (needed to verify it exists)
    RemoteAgent? agent;
    try {
      agent = await _databaseService?.getRemoteAgentById(targetAgentId);
    } catch (e) {
      LoggerService().error('Failed to load agent $targetAgentId', tag: 'ACPServer', error: e);
    }

    if (agent == null) {
      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.taskError,
        'params': {'task_id': taskId, 'message': 'Local agent not found: $targetAgentId'},
      });
      return;
    }

    // ── Ensure a persistent channel exists for this remote session ────────────
    final channelId = 'remote_${targetAgentId}_$sessionId';
    final db = _databaseService;
    if (db != null) {
      try {
        final existing = await db.getChannelById(channelId);
        if (existing == null) {
          final channel = Channel.withMemberIds(
            id: channelId,
            name: '${agent.name} ← $userName',
            type: 'dm',
            memberIds: [userId, targetAgentId],
            isPrivate: false,
          );
          await db.createChannel(channel, userId);
          LoggerService().debug('Created remote session channel: $channelId', tag: 'ACPServer');
        }
      } catch (e) {
        LoggerService().error('Failed to create remote session channel', tag: 'ACPServer', error: e);
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

    // Acknowledge the request immediately so the caller stops waiting on
    // sendChatMessage and switches to listening for streaming notifications.
    connection.sendResponse(ACPServerResponse.success(
      id: request.id,
      result: {'task_id': taskId, 'status': 'accepted'},
    ));

    // ── Execute via the full ChatService path ─────────────────────────────────
    // This reuses all agent configuration: OS tools, skills, tool models,
    // multi-round tool calling, multimodal attachments, system prompt, etc.
    final chatService = ChatService();
    final StringBuffer responseBuffer = StringBuffer();
    bool hasError = false;

    try {
      await chatService.sendMessageToAgent(
        content: message,
        agent: agent,
        userId: userId,
        userName: userName,
        channelId: channelId,
        existingUserMessage: null, // let ChatService create and persist the user message
        attachments: attachments,
        onStreamChunk: (chunk) {
          responseBuffer.write(chunk);
          // Forward each streamed chunk as an ACP ui.textContent notification
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiTextContent,
            'params': {
              'task_id': taskId,
              'content': chunk,
            },
          });
        },
        onActionConfirmation: (actionData) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiActionConfirmation,
            'params': {'task_id': taskId, ...actionData},
          });
        },
        onSingleSelect: (selectData) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiSingleSelect,
            'params': {'task_id': taskId, ...selectData},
          });
        },
        onMultiSelect: (selectData) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiMultiSelect,
            'params': {'task_id': taskId, ...selectData},
          });
        },
        onFileUpload: (uploadData) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiFileUpload,
            'params': {'task_id': taskId, ...uploadData},
          });
        },
        onForm: (formData) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiForm,
            'params': {'task_id': taskId, ...formData},
          });
        },
        onFileMessage: (fileData) async {
          final url = fileData['url'] as String? ?? '';
          // Detect if the url is a local file path (absolute path or file:// URI)
          final isLocalPath = url.startsWith('/') ||
              url.startsWith('file://') ||
              (url.length > 2 && url[1] == ':'); // Windows drive-letter path

          Map<String, dynamic> params = {'task_id': taskId, ...fileData};

          if (isLocalPath && url.isNotEmpty) {
            final localPath = url.startsWith('file://')
                ? Uri.parse(url).toFilePath()
                : url;
            // 生成 12 字符 file_id（去掉短横线的 uuid 前12位）
            final fileId = const Uuid().v4().replaceAll('-', '').substring(0, 12);
            _pendingFileTransfers[fileId] = localPath;
            params = {
              ...params,
              'url': '',          // 清空本地路径，app2 不尝试直接访问
              'file_id': fileId,  // app2 用此 id 通过 WS 取文件
            };
          }

          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiFileMessage,
            'params': params,
          });
        },
        onMessageMetadata: (metadata) {
          connection.send({
            'jsonrpc': '2.0',
            'method': ACPMethod.uiMessageMetadata,
            'params': {'task_id': taskId, ...metadata},
          });
        },
      );
    } catch (e) {
      hasError = true;
      LoggerService().error('Local LLM chat error for agent $targetAgentId', tag: 'ACPServer', error: e);
      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.taskError,
        'params': {
          'task_id': taskId,
          'message': e.toString(),
        },
      });
    }

    if (!hasError) {
      // Signal completion — include the full accumulated text for clients that
      // prefer to consume the response as a single block rather than chunks.
      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.taskCompleted,
        'params': {
          'task_id': taskId,
          'content': responseBuffer.toString(),
        },
      });
    }
  }

  /// Handle a JSON-RPC notification from an inbound Agent (ui.* methods).
  void _handleNotification(ACPClientConnection connection, Map<String, dynamic> json) {
    final method = json['method'] as String;
    final params = json['params'] as Map<String, dynamic>? ?? {};

    switch (method) {
      case ACPMethod.uiFileMessage:
        final agentId = connection.agentId;
        if (agentId != null) {
          onFileMessage?.call(agentId, connection.agentName ?? 'Agent', params);
        }
        break;
      case ACPMethod.fileTransferComplete:
        final agentId = connection.agentId;
        final fileId = params['file_id'] as String? ?? '';
        final totalBytes = params['total_bytes'] as int? ?? 0;
        if (agentId != null) {
          onFileTransferComplete?.call(agentId, fileId, totalBytes);
        }
        break;
      case ACPMethod.fileTransferError:
        final agentId = connection.agentId;
        final fileId = params['file_id'] as String? ?? '';
        final error = params['error'] as String? ?? 'Unknown error';
        if (agentId != null) {
          onFileTransferError?.call(agentId, fileId, error);
        }
        break;
      default:
        LoggerService().debug('Unhandled notification: $method', tag: 'ACPServer');
    }
  }

  /// 处理来自 app2 的 agent.requestFileData 请求
  /// 流式发送 binary frames，完成后发 file.transferComplete 通知
  Future<void> _handleAgentRequestFileData(
    ACPClientConnection connection,
    ACPServerRequest request,
  ) async {
    final fileId = request.params?['file_id'] as String?;
    if (fileId == null || fileId.isEmpty) {
      connection.sendResponse(ACPServerResponse.error(
        id: request.id,
        code: ACPErrorCode.invalidParams,
        message: 'Missing file_id',
      ));
      return;
    }

    final localPath = _pendingFileTransfers[fileId];
    if (localPath == null) {
      connection.sendResponse(ACPServerResponse.error(
        id: request.id,
        code: ACPErrorCode.notFound,
        message: 'File not found: $fileId',
      ));
      return;
    }

    final file = File(localPath);
    if (!await file.exists()) {
      connection.sendResponse(ACPServerResponse.error(
        id: request.id,
        code: ACPErrorCode.notFound,
        message: 'Local file does not exist',
      ));
      return;
    }

    final fileSize = await file.length();
    final ext = localPath.split('.').last.toLowerCase();
    final mimeType = _extToMime(ext);
    final filename = localPath.split('/').last;

    // 先回复元数据（filename, mime_type, size）
    connection.sendResponse(ACPServerResponse.success(
      id: request.id,
      result: {'filename': filename, 'mime_type': mimeType, 'size': fileSize},
    ));

    // 构造 16 字节帧头：[FILE magic 4B][file_id 12B null-padded]
    final fileIdBytes = Uint8List(12);
    final encoded = utf8.encode(fileId);
    final copyLen = encoded.length < 12 ? encoded.length : 12;
    fileIdBytes.setRange(0, copyLen, encoded);

    final header = Uint8List(16);
    header[0] = 0x46; header[1] = 0x49; header[2] = 0x4C; header[3] = 0x45; // "FILE"
    header.setRange(4, 16, fileIdBytes);

    // 流式发送 64KB 分块
    const chunkSize = 64 * 1024;
    try {
      final raf = await file.open();
      try {
        int offset = 0;
        while (offset < fileSize) {
          final readSize = (fileSize - offset) < chunkSize
              ? (fileSize - offset)
              : chunkSize;
          final chunk = await raf.read(readSize);
          if (chunk.isEmpty) break;

          final frame = Uint8List(16 + chunk.length);
          frame.setRange(0, 16, header);
          frame.setRange(16, 16 + chunk.length, chunk);
          connection.sendBinary(frame);
          offset += chunk.length;
        }
      } finally {
        await raf.close();
      }

      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.fileTransferComplete,
        'params': {'file_id': fileId, 'total_bytes': fileSize},
      });
      LoggerService().info(
        'File sent via WS binary: $filename ($fileSize bytes)',
        tag: 'ACPServer',
      );
    } catch (e) {
      connection.send({
        'jsonrpc': '2.0',
        'method': ACPMethod.fileTransferError,
        'params': {'file_id': fileId, 'error': e.toString()},
      });
      LoggerService().error('File WS send failed: $e', tag: 'ACPServer');
    }
  }

  /// 从文件扩展名推断 MIME 类型
  String _extToMime(String ext) {
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
      'pdf': 'application/pdf', 'txt': 'text/plain',
      'mp4': 'video/mp4', 'mov': 'video/quicktime',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav',
      'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  /// Parse a binary WebSocket frame containing a file chunk.
  /// Header: [4 bytes magic "FILE"] [12 bytes file_id, null-padded UTF-8] [rest: chunk data]
  void _handleBinaryFrame(ACPClientConnection connection, Uint8List data) {
    if (data.length < 16) return;

    // Validate magic bytes: 0x46494C45 ("FILE")
    if (data[0] != 0x46 || data[1] != 0x49 || data[2] != 0x4C || data[3] != 0x45) {
      LoggerService().debug('Binary frame with unknown magic, ignoring', tag: 'ACPServer');
      return;
    }

    // Extract file_id from bytes 4-16 (null-padded UTF-8)
    final fileIdBytes = data.sublist(4, 16);
    int nullIdx = fileIdBytes.indexOf(0);
    if (nullIdx == -1) nullIdx = 12;
    final fileId = String.fromCharCodes(fileIdBytes.sublist(0, nullIdx));

    // Extract payload from byte 16+
    final payload = data.sublist(16);
    final agentId = connection.agentId;
    if (agentId != null) {
      onFileChunk?.call(agentId, fileId, payload);
    }
  }

  /// Send a JSON-RPC request to a specific connected agent and wait for the response.
  Future<Map<String, dynamic>> sendRequestToAgent(
    String agentId,
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // Find a connection for the given agentId
    ACPClientConnection? targetConn;
    for (final conn in _connections.values) {
      if (conn.agentId == agentId) {
        targetConn = conn;
        break;
      }
    }
    if (targetConn == null) {
      throw Exception('No connection found for agent: $agentId');
    }

    final id = (++_serverRequestId).toString();
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
    };
    if (params != null) {
      request['params'] = params;
    }

    final completer = Completer<Map<String, dynamic>>();
    _pendingServerRequests[id] = completer;

    targetConn.send(request);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingServerRequests.remove(id);
        throw TimeoutException('Request timeout for $method to agent $agentId');
      },
    );
  }

  void _handleError(ACPClientConnection connection, dynamic error) {
    LoggerService().error('Connection error [${connection.id}]', tag: 'ACPServer', error: error);
  }

  void _handleDisconnect(ACPClientConnection connection) {
    LoggerService().debug('Connection closed: ${connection.id} (agent: ${connection.agentId})', tag: 'ACPServer');
    _connections.remove(connection.id);
    onAgentDisconnected?.call(connection.agentId);
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(
      Duration(seconds: config.heartbeatInterval),
      (_) => _checkHeartbeat(),
    );
  }

  void _checkHeartbeat() {
    final now = DateTime.now();
    final timeout = Duration(seconds: config.heartbeatInterval * 2);

    final disconnected = <String>[];
    for (final entry in _connections.entries) {
      if (now.difference(entry.value.lastActivityAt) > timeout) {
        disconnected.add(entry.key);
      }
    }

    for (final id in disconnected) {
      final conn = _connections.remove(id);
      if (conn != null) {
        onAgentDisconnected?.call(conn.agentId);
        conn.close();
      }
      LoggerService().debug('Connection timeout: $id', tag: 'ACPServer');
    }
  }

  void broadcastToChannel(String channelId, Map<String, dynamic> message) {
    for (final conn in _connections.values) {
      if (conn.subscribedChannels.contains(channelId)) {
        conn.send(message);
      }
    }
  }

  void sendToAgent(String agentId, Map<String, dynamic> message) {
    for (final conn in _connections.values) {
      if (conn.agentId == agentId) {
        conn.send(message);
      }
    }
  }
}
