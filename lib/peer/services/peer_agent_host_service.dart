/// Agent-over-Peer 提供方（host）服务。
///
/// 运行在「被访问」的一侧（如桌面）。监听配对设备通过 P2P 加密通道发来的
/// 控制消息：
/// - `agent_list_req`：返回本机所有「本地 agent 且允许外部访问」的列表。
/// - `agent_chat`：在本机用 [ChatService] 跑对应本地 agent，流式把文本块经
///   `agent_chunk` 回传，完成后发 `agent_done`，出错发 `agent_error`。
/// - `agent_cancel`：取消正在进行的请求。
/// - `agent_approval_resp`：配对客户端的工具审批回复；Hub 持久化后转发给本地 agent。
///
/// 当本地 agent 触发工具审批时，Hub 向客户端发送 `agent_approval_req` 并写入
/// `peer_hub_pending_approvals`，以便客户端延迟回复（杀进程 / 重连）后仍能完成 relay。
///
/// 每个来源设备的会话历史保存在独立 channel `peer__{peerId}__{agentId}` 下，
/// 天然提供多轮上下文；该 channel 会以「Agent 名 ← 来源设备名」的形式出现在
/// 本机被共享 agent 的会话列表里（与旧 ACP 远程连接的行为保持一致），让用户
/// 能看到本机 agent 被配对设备访问时产生的独立会话记录。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../services/acp_agent_connection.dart';
import '../../services/chat_service.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../services/task/task_models.dart';
import '../../service_locator.dart' show getIt;
import '../models/peer_hub_pending_approval.dart';
import 'peer_connection_manager.dart';
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import 'peer_storage_service.dart';

/// In-progress chunked file receive.
class _IncomingPeerFile {
  final String agentId;
  final String fileId;
  final String fileName;
  final String mimeType;
  final String semanticType;
  final int size;
  final Map<int, List<int>> chunks = {};

  _IncomingPeerFile({
    required this.agentId,
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.semanticType,
    required this.size,
  });
}

class _StoredPeerFile {
  final String agentId;
  final String relativePath;
  final String fileName;
  final String mimeType;
  final String semanticType;
  final int size;

  const _StoredPeerFile({
    required this.agentId,
    required this.relativePath,
    required this.fileName,
    required this.mimeType,
    required this.semanticType,
    required this.size,
  });
}

/// 桌面 peer-agent 会话 channelId 前缀。用于标识本机作为 host 时、为来自配对
/// 设备的请求维护的独立入站会话。
const String kPeerAgentChannelPrefix = 'peer__';

/// 构造一个来源设备 + agent（+ 来源端会话）的入站会话 channelId。
///
/// [clientSessionId] 为来源设备上的会话标识：传入时，每个来源会话映射到独立的
/// host channel，从而让来源端「新开会话」在本机也得到一条干净、无历史的新会话；
/// 不传时回退到按「设备 + agent」聚合的旧 channel（兼容旧版客户端）。
String peerAgentChannelId(String peerId, String agentId, [String? clientSessionId]) {
  final base = '$kPeerAgentChannelPrefix${peerId}__$agentId';
  if (clientSessionId == null || clientSessionId.isEmpty) return base;
  // 清洗来源会话 id，避免空白/异常字符影响 channelId。
  final safe = clientSessionId.replaceAll(RegExp(r'\s+'), '_');
  return '${base}__s_$safe';
}

/// 判断某 channelId 是否为 peer-agent 隐藏会话。
bool isPeerAgentChannel(String? channelId) =>
    channelId != null && channelId.startsWith(kPeerAgentChannelPrefix);

class _PeerChatSession {
  final String peerId;
  final String agentId;
  final String channelId;
  final String userId;
  final String userName;

  const _PeerChatSession({
    required this.peerId,
    required this.agentId,
    required this.channelId,
    required this.userId,
    required this.userName,
  });
}

class PeerAgentHostService {
  PeerAgentHostService._();
  static final PeerAgentHostService instance = PeerAgentHostService._();

  static const _tag = 'PeerAgentHost';
  final _log = LoggerService();

  StreamSubscription<PeerControlEvent>? _sub;
  StreamSubscription<PeerConnectionEvent>? _peerConnSub;
  bool _running = false;

  /// 正在进行的请求的取消令牌（requestId → token）。
  final Map<String, ACPCancellationToken> _activeRequests = {};

  /// In-flight peer chat sessions (requestId → context).
  final Map<String, _PeerChatSession> _chatSessions = {};

  /// In-progress file pushes (fileId → buffer state).
  final Map<String, _IncomingPeerFile> _incomingFiles = {};

  /// Completed peer file pushes (fileId → relative path under app storage).
  final Map<String, _StoredPeerFile> _storedFiles = {};

  LocalDatabaseService get _db => getIt<LocalDatabaseService>();
  ChatService get _chat => getIt<ChatService>();
  final PeerStorageService _peerStorage = PeerStorageService();
  final LocalFileStorageService _fileStorage = LocalFileStorageService();

  void start() {
    if (_running) return;
    _running = true;
    _sub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _peerConnSub = PeerConnectionManager.instance.events.listen((event) {
      if (event.type == PeerConnectionEventType.connected) {
        unawaited(_resendPendingApprovalsForPeer(event.peerId));
      }
    });
    unawaited(_replayDeferredHubApprovals());
    _log.info('PeerAgentHostService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    _peerConnSub?.cancel();
    _peerConnSub = null;
    for (final t in _activeRequests.values) {
      t.cancel();
    }
    _activeRequests.clear();
    _chatSessions.clear();
  }

  void _onControl(PeerControlEvent event) {
    switch (event.type) {
      case 'agent_list_req':
        unawaited(_handleListReq(event.peerId));
        break;
      case 'agent_chat':
        unawaited(_handleChat(event.peerId, event.data));
        break;
      case 'agent_cancel':
        _handleCancel(event.data);
        break;
      case 'agent_approval_resp':
        unawaited(_handleApprovalResp(event.peerId, event.data));
        break;
      case 'agent_file_begin':
        unawaited(_handleFileBegin(event.peerId, event.data));
        break;
      case 'agent_file_chunk':
        _handleFileChunk(event.peerId, event.data);
        break;
      case 'agent_file_end':
        unawaited(_handleFileEnd(event.peerId, event.data));
        break;
    }
  }

  Future<void> _handleListReq(String peerId) async {
    await pushAgentList(peerId);
  }

  /// 按「分享给该设备」的决定构建并推送可访问的 agent 列表。
  ///
  /// 设置页修改分享开关、或用户在弹窗中确认后，也通过此方法把最新列表推给对端，
  /// 对端据此即时增删本地的 peer agent。
  Future<void> pushAgentList(String peerId) async {
    try {
      final eligible = await _eligibleAgents();
      final sharedIds = await PeerStorageService().getSharedAgentIds(peerId);
      final shared = eligible.where((a) => sharedIds.contains(a.id)).toList();

      final exposed = <Map<String, dynamic>>[];
      // 所有头像共享一个传输预算：agent_list_resp 是单条控制消息，受帧大小限制，
      // 超预算的头像不附带字节，由对端回退到默认头像。
      var avatarBudget = _avatarBudgetBytes;
      for (final a in shared) {
        final entry = <String, dynamic>{
          'id': a.id,
          'name': a.name,
          'avatar': a.avatar,
          'bio': a.bio,
          'capabilities': a.capabilities,
        };
        // 头像若为本机文件（用户上传的自定义图片），对端无法访问该路径，
        // 故把图片字节一并打包发送，由对端落地为本地文件后展示。
        avatarBudget -= await _attachAvatarData(a.avatar, entry, avatarBudget);
        exposed.add(entry);
      }
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_list_resp',
        'agents': exposed,
      });
      _log.debug('Sent ${exposed.length} shared agents to $peerId', tag: _tag);
    } catch (e) {
      _log.warning('Failed to push agent list: $e', tag: _tag);
    }
  }

  /// 本机所有「本地且允许外部访问」的 agent —— 可被分享的候选集。
  Future<List<RemoteAgent>> _eligibleAgents() async {
    final agents = await _db.getAllRemoteAgents();
    return agents.where((a) => a.isLocal && a.allowExternalAccess).toList();
  }

  /// 单个头像随控制消息传输的体积上限（base64 前的原始字节）。
  static const int _maxAvatarBytes = 256 * 1024;

  /// 单条 agent_list_resp 中所有头像字节的总预算，避免拼包后超出帧大小限制。
  static const int _avatarBudgetBytes = 2 * 1024 * 1024;

  /// 若 [avatar] 是本机文件路径，读取其字节并以 base64 写入 [entry]
  /// （`avatar_data` + `avatar_ext`）。emoji / asset / 网络 URL 无需处理。
  /// 返回本次实际占用的字节数（未附带时为 0），供调用方扣减总预算。
  Future<int> _attachAvatarData(
      String avatar, Map<String, dynamic> entry, int budget) async {
    if (!avatar.startsWith('/')) return 0; // 非本机绝对路径，对端可直接解析
    try {
      final file = File(avatar);
      if (!await file.exists()) return 0;
      final len = await file.length();
      if (len <= 0 || len > _maxAvatarBytes || len > budget) return 0;
      final bytes = await file.readAsBytes();
      var ext = avatar.contains('.') ? avatar.split('.').last.toLowerCase() : 'png';
      if (ext.length > 5) ext = 'png';
      entry['avatar_data'] = base64Encode(bytes);
      entry['avatar_ext'] = ext;
      return len;
    } catch (e) {
      _log.warning('Failed to attach avatar data for $avatar: $e', tag: _tag);
      return 0;
    }
  }

  Future<void> _handleFileBegin(String peerId, Map<String, dynamic> data) async {
    final fileId = data['file_id'] as String?;
    final agentId = data['agent_id'] as String?;
    final fileName = data['file_name'] as String? ?? 'file';
    final mimeType = data['mime_type'] as String? ?? 'application/octet-stream';
    final semanticType = data['file_type'] as String? ??
        data['semantic_type'] as String? ??
        'file';
    final size = data['size'] as int? ?? 0;

    if (fileId == null || fileId.isEmpty || agentId == null || agentId.isEmpty) {
      return;
    }

    Future<void> reject(String message) async {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_error',
        'file_id': fileId,
        'message': message,
      });
    }

    if (size <= 0 || size > AttachmentData.maxSizeBytes) {
      await reject('invalid or oversized file ($size bytes)');
      return;
    }

    try {
      final agent = await _db.getRemoteAgentById(agentId);
      if (agent == null || !agent.isLocal || !agent.allowExternalAccess) {
        await reject('Agent not available for external access');
        return;
      }
    } catch (e) {
      await reject('Failed to validate agent: $e');
      return;
    }

    _incomingFiles[fileId] = _IncomingPeerFile(
      agentId: agentId,
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
      semanticType: semanticType,
      size: size,
    );
  }

  void _handleFileChunk(String peerId, Map<String, dynamic> data) {
    final fileId = data['file_id'] as String?;
    final index = data['index'] as int?;
    final b64 = data['data'] as String?;
    if (fileId == null || index == null || b64 == null) return;
    final incoming = _incomingFiles[fileId];
    if (incoming == null) return;
    try {
      incoming.chunks[index] = base64Decode(b64);
    } catch (e) {
      _incomingFiles.remove(fileId);
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_error',
        'file_id': fileId,
        'message': 'Invalid chunk: $e',
      }));
    }
  }

  Future<void> _handleFileEnd(String peerId, Map<String, dynamic> data) async {
    final fileId = data['file_id'] as String?;
    final chunkCount = data['chunk_count'] as int? ?? 0;
    if (fileId == null) return;
    final incoming = _incomingFiles.remove(fileId);
    if (incoming == null) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_ack',
        'file_id': fileId,
        'ok': false,
        'error': 'unknown file_id',
      });
      return;
    }

    try {
      if (incoming.chunks.length != chunkCount) {
        throw StateError(
          'chunk count mismatch: got ${incoming.chunks.length}, expected $chunkCount',
        );
      }
      final ordered = <int>[];
      for (var i = 0; i < chunkCount; i++) {
        final part = incoming.chunks[i];
        if (part == null) {
          throw StateError('missing chunk $i');
        }
        ordered.addAll(part);
      }
      if (ordered.length != incoming.size && incoming.size > 0) {
        // Allow slight mismatch only if size was approximate; prefer exact.
        if (ordered.length > AttachmentData.maxSizeBytes) {
          throw StateError('assembled file exceeds size limit');
        }
      }
      final bytes = Uint8List.fromList(ordered);
      if (bytes.length > AttachmentData.maxSizeBytes) {
        throw StateError('assembled file exceeds size limit');
      }

      final relativePath = await _fileStorage.savePeerInboundBytes(
        agentId: incoming.agentId,
        fileId: incoming.fileId,
        fileName: AttachmentData.safeFileName(incoming.fileName),
        bytes: bytes,
      );
      _storedFiles[fileId] = _StoredPeerFile(
        agentId: incoming.agentId,
        relativePath: relativePath,
        fileName: incoming.fileName,
        mimeType: incoming.mimeType,
        semanticType: incoming.semanticType,
        size: bytes.length,
      );
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_ack',
        'file_id': fileId,
        'ok': true,
      });
    } catch (e) {
      _log.warning('agent_file_end failed: $e', tag: _tag);
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_ack',
        'file_id': fileId,
        'ok': false,
        'error': e.toString(),
      });
    }
  }

  Future<List<AttachmentData>?> _resolveAttachmentRefs(
    String agentId,
    dynamic raw,
  ) async {
    final refs = AttachmentData.peerRefListFromJson(raw);
    if (refs == null) return null;
    final out = <AttachmentData>[];
    for (final ref in refs) {
      final fileId = ref['file_id'] as String;
      final stored = _storedFiles[fileId];
      if (stored == null || stored.agentId != agentId) {
        throw Exception('Unknown or mismatched attachment file_id: $fileId');
      }
      final fullPath = await _fileStorage.getFullPath(stored.relativePath);
      final file = File(fullPath);
      if (!await file.exists()) {
        throw Exception('Attachment file missing on host: $fileId');
      }
      final bytes = await file.readAsBytes();
      out.add(AttachmentData(
        fileName: stored.fileName,
        mimeType: stored.mimeType,
        sizeBytes: stored.size,
        bytes: bytes,
        semanticType: stored.semanticType,
        fileId: fileId,
      ));
    }
    return out;
  }

  Future<void> _persistInboundAttachmentMessages({
    required String channelId,
    required String userId,
    required String userName,
    required List<AttachmentData> attachments,
  }) async {
    for (final att in attachments) {
      final fileId = att.fileId;
      if (fileId == null) continue;
      final stored = _storedFiles[fileId];
      if (stored == null) continue;
      final messageType = switch (att.semanticType) {
        'image' => 'image',
        'audio' => 'audio',
        _ => 'file',
      };
      final metadata = {
        'path': stored.relativePath,
        'name': stored.fileName,
        'type': stored.semanticType,
        'size': stored.size,
        'file_id': fileId,
      };
      final id = Uuid().v4();
      await _db.createMessage(
        id: id,
        channelId: channelId,
        senderId: userId,
        senderType: 'user',
        senderName: userName,
        content: att.textDescription,
        messageType: messageType,
        metadata: metadata,
      );
    }
  }

  Future<void> _handleChat(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String?;
    final agentId = data['agent_id'] as String?;
    final message = data['message'] as String? ?? '';
    final clientSessionId = data['session_id'] as String?;
    if (requestId == null || agentId == null) return;

    final token = ACPCancellationToken();
    _activeRequests[requestId] = token;

    final channelId = peerAgentChannelId(peerId, agentId, clientSessionId);
    final userName = await _peerDisplayName(peerId);
    final userId = 'peer:$peerId';
    _chatSessions[requestId] = _PeerChatSession(
      peerId: peerId,
      agentId: agentId,
      channelId: channelId,
      userId: userId,
      userName: userName,
    );

    try {
      final agent = await _db.getRemoteAgentById(agentId);
      if (agent == null || !agent.isLocal || !agent.allowExternalAccess) {
        await _sendError(peerId, requestId, 'Agent not available for external access');
        return;
      }

      // 为该来源设备的入站会话维护持久化 channel（与旧 ACP 远程连接逻辑对齐），
      // 标题统一标注「Agent 名 ← 来源设备名」，使本机能在会话列表中分辨出这条
      // 会话来自哪个配对设备。channel 不存在则创建；已存在但标题未正确标注来源
      // 设备（如历史遗留的通用名称、或对端设备改名）时则刷新标题。
      final sessionTitle = '${agent.name} ← $userName';
      try {
        final existing = await _db.getChannelById(channelId);
        if (existing == null) {
          final channel = Channel.withMemberIds(
            id: channelId,
            name: sessionTitle,
            type: 'dm',
            memberIds: [userId, agentId],
            isPrivate: false,
          );
          await _db.createChannel(channel, userId);
          _log.debug('Created peer session channel: $channelId', tag: _tag);
        } else if (existing.name != sessionTitle) {
          await _db.updateChannel(existing.copyWith(name: sessionTitle));
          _log.debug('Refreshed peer session title: $channelId -> $sessionTitle', tag: _tag);
        }
      } catch (e) {
        _log.warning('Failed to ensure peer session channel: $e', tag: _tag);
      }

      final attachments = await _resolveAttachmentRefs(agentId, data['attachments']);
      if (attachments != null && attachments.isNotEmpty) {
        await _persistInboundAttachmentMessages(
          channelId: channelId,
          userId: userId,
          userName: userName,
          attachments: attachments,
        );
      }

      var response = await _chat.sendMessageToAgent(
        content: message,
        agent: agent,
        userId: userId,
        userName: userName,
        channelId: channelId,
        acpCancellationToken: token,
        attachments: attachments,
        // Relay raw stream; the phone client folds progress once.
        foldProgressContent: false,
        onStreamChunk: (chunk) {
          unawaited(PeerConnectionManager.instance.sendControl(peerId, {
            'type': 'agent_chunk',
            'request_id': requestId,
            'content': chunk,
          }));
        },
        onMessageMetadata: (data) {
          unawaited(PeerConnectionManager.instance.sendControl(peerId, {
            'type': 'agent_metadata',
            'request_id': requestId,
            'metadata': data,
          }));
        },
        onActionConfirmation: (data) {
          unawaited(_relayApprovalRequest(
            session: _chatSessions[requestId]!,
            requestId: requestId,
            data: data,
          ));
        },
      );

      // Async-confirmation agents return null from sendMessageToAgent before the
      // SDK turn (and any tool approvals) finish. Do not send agent_done yet —
      // the paired client's group-chat sendChat must stay open until approvals
      // are resolved and the hub task actually completes.
      if (response == null) {
        response = await _awaitAsyncHubTaskMessage(
          channelId: channelId,
          cancelToken: token,
        );
      }

      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_done',
        'request_id': requestId,
        'content': response?.content ?? '',
        'message_id': response?.id,
        'metadata': response?.metadata,
      });
    } catch (e) {
      _log.warning('agent_chat failed: $e', tag: _tag);
      await _sendError(peerId, requestId, e.toString());
    } finally {
      _activeRequests.remove(requestId);
      _chatSessions.remove(requestId);
    }
  }

  /// After [sendMessageToAgent] returns null (async-confirmation path), block until
  /// the hub-side task finishes and its response is persisted.
  Future<Message?> _awaitAsyncHubTaskMessage({
    required String channelId,
    required ACPCancellationToken cancelToken,
  }) async {
    const timeout = Duration(minutes: 30);
    final deadline = DateTime.now().add(timeout);

    ActiveTask? task;
    while (task == null && DateTime.now().isBefore(deadline)) {
      if (cancelToken.isCancelled) {
        return Message(
          id: 'peer_stopped_${DateTime.now().millisecondsSinceEpoch}',
          content: '[Stopped]',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: 'system', type: 'system', name: 'System'),
          type: MessageType.text,
        );
      }
      task = _chat.getActiveTask(channelId);
      if (task == null) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    if (task == null) {
      _log.warning(
        'Async peer hub task never registered for channel $channelId',
        tag: _tag,
      );
      return null;
    }

    try {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('Peer hub async task timed out');
      }
      await task.dbSaveCompleter.future.timeout(remaining);
    } on TimeoutException {
      _log.warning(
        'Async peer hub task timed out for channel $channelId',
        tag: _tag,
      );
      final partial = task.accumulatedContent;
      return Message(
        id: 'peer_timeout_${DateTime.now().millisecondsSinceEpoch}',
        content: partial.isNotEmpty ? partial : 'Task timed out',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: task.agentId, type: 'agent', name: task.agentName),
        type: MessageType.text,
        metadata: task.metadata,
      );
    }

    try {
      final rows = await _db.getChannelMessages(channelId, limit: 10);
      for (final row in rows) {
        if ((row['sender_type'] as String?) != 'agent') continue;
        Map<String, dynamic>? meta;
        final metaRaw = row['metadata_json'] as String?;
        if (metaRaw != null && metaRaw.isNotEmpty) {
          try {
            meta = Map<String, dynamic>.from(jsonDecode(metaRaw) as Map);
          } catch (_) {}
        }
        return Message(
          id: row['id'] as String? ?? 'peer_done_${DateTime.now().millisecondsSinceEpoch}',
          content: row['content'] as String? ?? '',
          timestampMs: row['created_at'] is int
              ? row['created_at'] as int
              : DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(
            id: row['sender_id'] as String? ?? task.agentId,
            type: 'agent',
            name: row['sender_name'] as String? ?? task.agentName,
          ),
          type: MessageType.text,
          metadata: meta ?? task.metadata,
        );
      }
    } catch (e) {
      _log.warning(
        'Failed to load async peer hub result from DB: $e',
        tag: _tag,
      );
    }

    final fallback = task.accumulatedContent;
    return Message(
      id: 'peer_done_${DateTime.now().millisecondsSinceEpoch}',
      content: fallback.isNotEmpty ? fallback : 'Task completed',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: task.agentId, type: 'agent', name: task.agentName),
      type: MessageType.text,
      metadata: task.metadata,
    );
  }

  /// Forward a local agent tool approval to the paired client and persist it
  /// on the hub so a delayed `agent_approval_resp` can still be relayed.
  Future<void> _relayApprovalRequest({
    required _PeerChatSession session,
    required String requestId,
    required Map<String, dynamic> data,
  }) async {
    final approvalId = data['confirmation_id'] as String? ??
        data['approval_id'] as String? ??
        '';
    if (approvalId.isEmpty) {
      _log.warning('peer approval relay: missing confirmation_id', tag: _tag);
      return;
    }

    final activeTask = _chat.getActiveTask(session.channelId);
    final taskId = activeTask?.taskId ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;

    final record = PeerHubPendingApproval(
      approvalId: approvalId,
      peerId: session.peerId,
      requestId: requestId,
      agentId: session.agentId,
      taskId: taskId,
      channelId: session.channelId,
      approvalData: Map<String, dynamic>.from(data),
      createdAt: now,
      expiresAt: now + PeerStorageService.defaultApprovalTtlMs,
    );

    try {
      await _peerStorage.saveHubPendingApproval(record);
    } catch (e) {
      _log.warning('Failed to persist hub pending approval: $e', tag: _tag);
    }

    final payload = <String, dynamic>{
      'type': 'agent_approval_req',
      'request_id': requestId,
      'approval_id': approvalId,
      'prompt': data['prompt'] ?? '',
      'actions': data['actions'] ?? const [],
      if (data['tool_kind'] != null) 'tool_kind': data['tool_kind'],
      if (data['tool_call_id'] != null) 'tool_call_id': data['tool_call_id'],
    };

    final sent = await PeerConnectionManager.instance.sendControl(
      session.peerId,
      payload,
    );
    _log.info(
      'Relayed agent_approval_req approvalId=$approvalId requestId=$requestId '
      'peerId=${session.peerId} sent=$sent',
      tag: _tag,
    );
  }

  Future<void> _handleApprovalResp(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    final approvalId = data['approval_id'] as String? ?? '';
    final selectedActionId = data['selected_action_id'] as String? ?? '';
    final selectedActionLabel = data['selected_action_label'] as String?;
    if (approvalId.isEmpty || selectedActionId.isEmpty) {
      _log.warning('agent_approval_resp missing id fields', tag: _tag);
      return;
    }

    _log.info(
      'agent_approval_resp approvalId=$approvalId actionId=$selectedActionId '
      'peerId=$peerId',
      tag: _tag,
    );

    final record = await _peerStorage.getHubPendingApproval(approvalId);
    if (record != null && record.peerId != peerId) {
      _log.warning(
        'agent_approval_resp peer mismatch: expected ${record.peerId}, got $peerId',
        tag: _tag,
      );
      return;
    }

    if (record != null && !record.isPending) {
      _log.debug('agent_approval_resp already handled: $approvalId', tag: _tag);
      return;
    }

    _PeerChatSession? session;
    if (record != null) {
      session = _PeerChatSession(
        peerId: record.peerId,
        agentId: record.agentId,
        channelId: record.channelId,
        userId: 'peer:${record.peerId}',
        userName: await _peerDisplayName(record.peerId),
      );
    } else {
      for (final s in _chatSessions.values) {
        if (s.peerId == peerId) {
          session = s;
          break;
        }
      }
    }

    if (session == null) {
      _log.warning(
        'agent_approval_resp with no persisted/active session: $approvalId',
        tag: _tag,
      );
      return;
    }

    final submitted = await _submitApprovalToLocalAgent(
      session: session,
      approvalId: approvalId,
      taskId: record?.taskId,
      selectedActionId: selectedActionId,
      selectedActionLabel: selectedActionLabel,
    );

    if (submitted) {
      await _peerStorage.markHubPendingApprovalSubmitted(
        approvalId,
        selectedActionId: selectedActionId,
        selectedActionLabel: selectedActionLabel,
      );
    }
  }

  /// Relay the user's verdict to the local agent. Returns true on success.
  Future<bool> _submitApprovalToLocalAgent({
    required _PeerChatSession session,
    required String approvalId,
    String? taskId,
    required String selectedActionId,
    String? selectedActionLabel,
  }) async {
    final agent = await _db.getRemoteAgentById(session.agentId);
    if (agent == null) return false;

    final activeTask = _chat.getActiveTask(session.channelId);
    final effectiveTaskId = taskId ?? activeTask?.taskId ?? '';
    final responseData = <String, dynamic>{
      'confirmation_id': approvalId,
      'selected_action_id': selectedActionId,
      if (selectedActionLabel != null && selectedActionLabel.isNotEmpty)
        'selected_action_label': selectedActionLabel,
    };

    final acpConn = _chat.getACPConnection(session.agentId);
    if (acpConn != null &&
        acpConn.isConnected &&
        !acpConn.supportsAsyncConfirmation) {
      try {
        await acpConn.submitResponse(
          taskId: effectiveTaskId,
          responseType: 'action_confirmation',
          responseData: responseData,
        );
        _log.info(
          'Submitted approval via ACP submitResponse taskId=$effectiveTaskId',
          tag: _tag,
        );
        return true;
      } catch (e) {
        _log.warning('ACP submitResponse failed: $e', tag: _tag);
      }
    }

    final connection = _chat.getInteractiveConnection(agent);
    if (connection != null &&
        !connection.supportsAsyncConfirmation &&
        connection.isConnected) {
      try {
        await connection.submitResponse(
          taskId: effectiveTaskId,
          responseType: 'action_confirmation',
          responseData: responseData,
        );
        return true;
      } catch (e) {
        _log.warning('Interactive submitResponse failed: $e', tag: _tag);
      }
    }

    // Deferred / local-LLM fallback: issue a verdict chat on the peer session.
    try {
      final label = selectedActionLabel ?? selectedActionId;
      await _chat.sendMessageToAgent(
        content: 'Selected action: $label',
        agent: agent,
        userId: session.userId,
        userName: session.userName,
        channelId: session.channelId,
      );
      _log.info('Submitted approval via verdict chat fallback', tag: _tag);
      return true;
    } catch (e) {
      _log.warning('Verdict chat fallback failed: $e', tag: _tag);
      return false;
    }
  }

  /// On hub restart, re-notify connected clients of approvals still pending.
  Future<void> _replayDeferredHubApprovals() async {
    try {
      await _peerStorage.expireStaleHubPendingApprovals();
      final connected = PeerConnectionManager.instance.connectedPeerIds;
      for (final peerId in connected) {
        await _resendPendingApprovalsForPeer(peerId);
      }
    } catch (e) {
      _log.warning('Deferred hub approval replay failed: $e', tag: _tag);
    }
  }

  Future<void> _resendPendingApprovalsForPeer(String peerId) async {
    try {
      final pending = await _peerStorage.getPendingHubApprovals();
      var resent = 0;
      for (final record in pending) {
        if (record.peerId != peerId) continue;
        final data = record.approvalData;
        final sent = await PeerConnectionManager.instance.sendControl(
          record.peerId,
          {
            'type': 'agent_approval_req',
            'request_id': record.requestId,
            'approval_id': record.approvalId,
            'prompt': data['prompt'] ?? '',
            'actions': data['actions'] ?? const [],
            if (data['tool_kind'] != null) 'tool_kind': data['tool_kind'],
            if (data['tool_call_id'] != null)
              'tool_call_id': data['tool_call_id'],
          },
        );
        if (sent) resent++;
      }
      if (resent > 0) {
        _log.info(
          'Re-sent $resent pending approval(s) to peer $peerId',
          tag: _tag,
        );
      }
    } catch (e) {
      _log.warning('Resend pending approvals failed for $peerId: $e', tag: _tag);
    }
  }

  void _handleCancel(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    _activeRequests[requestId]?.cancel();
  }

  Future<void> _sendError(String peerId, String requestId, String message) async {
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_error',
      'request_id': requestId,
      'message': message,
    });
  }

  Future<String> _peerDisplayName(String peerId) async {
    try {
      final peers = await PeerStorageService().loadAllPeers();
      for (final p in peers) {
        if (p.id == peerId) return p.deviceName;
      }
    } catch (_) {}
    return 'Paired Device';
  }
}
