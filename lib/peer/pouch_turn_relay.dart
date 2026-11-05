import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/client_device_info.dart';
import '../../models/message.dart';
import '../../services/local_database_service.dart';
import '../../storage/pouch_login.dart';
import '../../storage/pouch_role.dart';
import '../../storage/pouch_session.dart';
import 'pouch_attachment.dart';
import 'services/hub_group_sessions.dart';
import 'services/peer_connection_manager.dart';
import 'services/peer_inflight_turn.dart';

/// 客户端把群编排 / 本机回合交给持有储物袋的主机。
///
/// 主机收到后在本机跑现有的 [ChatService] 路径，再用事件帧把流式结果送回。
class PouchTurnRelay {
  PouchTurnRelay._();

  static final PouchTurnRelay instance = PouchTurnRelay._();

  static const groupRequestType = 'pouch_group_turn';
  static const dmRequestType = 'pouch_dm_turn';
  static const readRequestType = 'pouch_chat_read';
  static const interactionResponseType = 'pouch_interaction_resp';
  static const eventType = 'pouch_turn_event';

  static const queueRequestType = 'pouch_session_queue';

  static const controlTypes = <String>[
    groupRequestType,
    dmRequestType,
    readRequestType,
    interactionResponseType,
    eventType,
    queueRequestType,
  ];

  static const _pendingReadPrefsKey = 'pouch_pending_read_channels_v1';
  static const _pendingReadAllAgentsPrefsKey =
      'pouch_pending_read_all_agents_v1';

  final _uuid = const Uuid();
  final _pending = <String, _PendingTurn>{};
  final _lanes = <String, Future<void>>{};
  final _pendingReadChannelIds = <String>{};
  final _pendingReadAgentByChannel = <String, String>{};
  final _pendingReadAllAgentIds = <String>{};
  Timer? _markReadDebounceTimer;
  bool _flushingReads = false;
  final _files = PouchAttachmentClient(
    send: (peerId, frame) =>
        PeerConnectionManager.instance.sendControl(peerId, frame),
  );

  void onFileAck(Map<String, dynamic> data) => _files.onAck(data);

  /// App 不在本机跑回合。没登录袋子就停，不退回本地编排。
  static Future<PouchTurnRoute> currentRoute() async {
    final session = await PouchSessionStore.readActive();
    if (session == null) {
      throw StateError('请先登录储物袋');
    }
    if (session.isLoggedIn(DateTime.now().millisecondsSinceEpoch)) {
      PouchChannel.install(session);
    }
    return PouchTurnRoute.decide(PouchRole.client(session.hostPeerId));
  }

  /// 群回合帧（协议 v2）：带 `pouch_id`、`group_id`，以及这一端选过的
  /// `session_id`。没选过就不带，主机取群 meta 的 current_session。
  static Map<String, dynamic> groupTurnFrame({
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required Map<String, dynamic> deviceInfo,
    String pouchId = '',
    String groupId = '',
    String? sessionId,
    String? userMessageId,
    List<String> mentionedAgentIds = const [],
    String? replyToId,
    String? replyQuoteText,
    List<Map<String, dynamic>>? attachmentRefs,
    // 设计视图点选的上下文（C.3）：`{flow: {ref}, selection: [...]}`，主机据此
    // 把选中节点的原文带给群主，不必用语言描述"第二个并行里那个"。
    Map<String, dynamic>? flowContext,
  }) {
    return <String, dynamic>{
      'type': groupRequestType,
      if (pouchId.isNotEmpty) 'pouch_id': pouchId,
      'channel_id': channelId,
      if (groupId.isNotEmpty) 'group_id': groupId,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      'content': content,
      'user_id': userId,
      'user_name': userName,
      if (flowContext != null) ...flowContext,
      if (userMessageId != null)
        'user_message_id': bareMessageId(userMessageId),
      'mentioned_agent_ids': mentionedAgentIds,
      if (replyToId != null) 'reply_to_id': bareMessageId(replyToId),
      if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
      if (attachmentRefs != null) 'attachments': attachmentRefs,
      ...deviceInfo,
    };
  }

  Future<void> forwardGroup({
    required String hostPeerId,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    String? userMessageId,
    List<String> mentionedAgentIds = const [],
    String? replyToId,
    String? replyQuoteText,
    List<AttachmentData>? attachments,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
    void Function(
            String agentId, String agentName, Map<String, dynamic> metadata)?
        onMessageMetadata,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,

    /// 主机回显本轮实际用的会话和任务（B 4.5）。
    void Function(String sessionId, String? taskId)? onSessionResolved,

    /// 设计视图点选的上下文（C.3），原样并进群回合帧。
    Map<String, dynamic>? flowContext,
  }) async {
    final refs = await _attachmentRefs(
      hostPeerId: hostPeerId,
      attachments: attachments,
      agentId: 'she-builtin-agent-001',
      channelId: channelId,
      placement: 'group',
    );
    final deviceInfo = await ClientDeviceInfo.current();
    final pouchId = (await PouchSessionStore.readActive())?.pouchId ?? '';
    final groupId = channelId.startsWith('group_') ? channelId : '';
    final sessionId =
        groupId.isEmpty ? null : GroupSessionSelection.of(groupId);
    await _forward(
      hostPeerId: hostPeerId,
      channelId: channelId,
      frame: groupTurnFrame(
        channelId: channelId,
        content: content,
        userId: userId,
        userName: userName,
        deviceInfo: deviceInfo.toWireFields(),
        pouchId: pouchId,
        groupId: groupId,
        sessionId: sessionId,
        userMessageId: userMessageId,
        mentionedAgentIds: mentionedAgentIds,
        replyToId: replyToId,
        replyQuoteText: replyQuoteText,
        attachmentRefs: refs,
        flowContext: flowContext,
      ),
      onEvent: (event) {
        if (event['kind'] == 'interaction') {
          unawaited(_answerInteraction(
            hostPeerId: hostPeerId,
            event: event,
            onInteractionRequest: onInteractionRequest,
          ));
          return;
        }
        final agentId = event['agent_id'] as String? ?? '';
        final agentName = event['agent_name'] as String? ?? '';
        switch (event['kind']) {
          case 'start':
            onAgentStart?.call(agentId, agentName);
          case 'metadata':
            final raw = event['metadata'];
            if (raw is Map) {
              onMessageMetadata?.call(
                agentId,
                agentName,
                Map<String, dynamic>.from(raw),
              );
            }
          case 'chunk':
            onStreamChunk?.call(
              agentId,
              agentName,
              event['chunk'] as String? ?? '',
            );
          case 'agent_done':
            onAgentDone?.call(agentId, agentName, event['skipped'] == true);
          case 'done':
            final resolved = event['session_id'] as String? ?? '';
            final taskId = event['task_id'] as String?;
            if (resolved.isNotEmpty && groupId.isNotEmpty) {
              GroupSessionSelection.select(groupId, resolved);
            }
            onSessionResolved?.call(resolved, taskId);
            onAllDone?.call();
        }
      },
    );
  }

  /// 把本机 LLM 回合交给主机。返回主机流式拼出的正文，以及主机记下的回复 id。
  Future<({String text, String? agentMessageId})> forwardDm({
    required String hostPeerId,
    required String agentId,
    required String content,
    required String userId,
    required String userName,
    String? channelId,
    String? userMessageId,
    String? replyToId,
    String? replyQuoteText,
    List<AttachmentData>? attachments,
    void Function(String chunk)? onStreamChunk,

    /// 主机下发的折叠区元数据（思考、工具步骤），字段同 `agent_metadata`。
    void Function(Map<String, dynamic> metadata)? onMetadata,

    /// 模型的推理文本片段，不属于回复正文。
    void Function(String chunk)? onThinking,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    final buffer = StringBuffer();
    final refs = await _attachmentRefs(
      hostPeerId: hostPeerId,
      attachments: attachments,
      agentId: agentId,
      channelId: channelId ?? '',
      placement: 'dm',
    );
    final deviceInfo = await ClientDeviceInfo.current();
    final pouchId = (await PouchSessionStore.readActive())?.pouchId ?? '';
    final done = await _forward(
      hostPeerId: hostPeerId,
      channelId: channelId,
      frame: <String, dynamic>{
        'type': dmRequestType,
        if (pouchId.isNotEmpty) 'pouch_id': pouchId,
        'agent_id': agentId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
        if (userMessageId != null)
          'user_message_id': bareMessageId(userMessageId),
        if (replyToId != null) 'reply_to_id': bareMessageId(replyToId),
        if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
        if (channelId != null) 'channel_id': channelId,
        if (refs != null) 'attachments': refs,
        ...deviceInfo.toWireFields(),
      },
      onEvent: (event) {
        if (event['kind'] == 'interaction') {
          unawaited(_answerInteraction(
            hostPeerId: hostPeerId,
            event: event,
            onInteractionRequest: onInteractionRequest,
          ));
          return;
        }
        if (event['kind'] == 'metadata') {
          final raw = event['metadata'];
          if (raw is Map) onMetadata?.call(Map<String, dynamic>.from(raw));
          return;
        }
        if (event['kind'] == 'thinking') {
          final chunk = event['chunk'] as String? ?? '';
          if (chunk.isNotEmpty) onThinking?.call(chunk);
          return;
        }
        if (event['kind'] == 'chunk') {
          final chunk = event['chunk'] as String? ?? '';
          buffer.write(chunk);
          onStreamChunk?.call(chunk);
        }
      },
    );
    final agentMessageId = (done['agent_message_id'] as String?)?.trim();
    return (
      text: buffer.toString(),
      agentMessageId: agentMessageId == null || agentMessageId.isEmpty
          ? null
          : agentMessageId,
    );
  }

  /// 向主机要一页消息，或一个条数。本机和远程都从这里进。
  Future<PouchChatReadBody> readChat({
    required String hostPeerId,
    required String op,
    required String channelId,
    int? limit,
    String? beforeCreatedAt,
    String? messageId,
    bool compact = false,
  }) async {
    final pouchId = (await PouchSessionStore.readActive())?.pouchId ?? '';
    final done = await _forward(
      hostPeerId: hostPeerId,
      frame: <String, dynamic>{
        'type': readRequestType,
        if (pouchId.isNotEmpty) 'pouch_id': pouchId,
        'op': op,
        'channel_id': channelId,
        if (limit != null) 'limit': limit,
        if (beforeCreatedAt != null) 'before_created_at': beforeCreatedAt,
        if (messageId != null) 'message_id': messageId,
        if (compact) 'compact': true,
      },
      onEvent: (_) {},
    );
    return PouchChatReadBody.decode(done);
  }

  /// 将频道已读状态同步到主机（合并短时间内的批量已读；离线时持久化待重连补发）。
  void scheduleMarkRead(
    String channelId, {
    String? agentId,
    bool allSessions = false,
  }) {
    final trimmed = channelId.trim();
    final trimmedAgent = agentId?.trim() ?? '';
    if (allSessions && trimmedAgent.isNotEmpty) {
      _pendingReadAllAgentIds.add(trimmedAgent);
    }
    if (trimmed.isNotEmpty &&
        !trimmed.startsWith('gmd_') &&
        !trimmed.startsWith('shed_')) {
      _pendingReadChannelIds.add(trimmed);
      if (trimmedAgent.isNotEmpty) {
        _pendingReadAgentByChannel[trimmed] = trimmedAgent;
      }
    }
    if (_pendingReadChannelIds.isEmpty && _pendingReadAllAgentIds.isEmpty) {
      return;
    }
    _markReadDebounceTimer?.cancel();
    _markReadDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      _markReadDebounceTimer = null;
      unawaited(flushPendingReads());
    });
  }

  /// 立即向主机发送挂起的已读频道列表；离线或发送失败时保留在本地等待下次重连补发。
  Future<void> flushPendingReads([String? explicitHostPeerId]) async {
    if (_flushingReads) return;
    _flushingReads = true;
    try {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getStringList(_pendingReadPrefsKey);
        if (saved != null && saved.isNotEmpty) {
          _pendingReadChannelIds.addAll(saved.where((s) => s.isNotEmpty));
        }
        final savedAgents = prefs.getStringList(_pendingReadAllAgentsPrefsKey);
        if (savedAgents != null && savedAgents.isNotEmpty) {
          _pendingReadAllAgentIds.addAll(
            savedAgents.where((s) => s.isNotEmpty),
          );
        }
      } catch (_) {}

      final outboxOpIds = <String>[];
      try {
        final ops =
            await LocalDatabaseService().listPendingOps(kind: 'mark_read');
        for (final row in ops) {
          final opId = row['op_id'] as String? ?? '';
          if (opId.isNotEmpty) outboxOpIds.add(opId);
          final rawPayload = row['payload'] as String? ?? '';
          if (rawPayload.isEmpty) continue;
          final decoded = jsonDecode(rawPayload);
          if (decoded is! Map) continue;
          final cid = (decoded['channel_id'] as String?)?.trim() ?? '';
          final aid = (decoded['agent_id'] as String?)?.trim() ?? '';
          final all = decoded['all_sessions'] == true;
          if (all && aid.isNotEmpty) {
            _pendingReadAllAgentIds.add(aid);
          }
          if (cid.isNotEmpty) {
            _pendingReadChannelIds.add(cid);
            if (aid.isNotEmpty) {
              _pendingReadAgentByChannel[cid] = aid;
            }
          }
        }
      } catch (_) {}

      if (_pendingReadChannelIds.isEmpty && _pendingReadAllAgentIds.isEmpty) {
        return;
      }

      String? hostPeerId = explicitHostPeerId;
      if (hostPeerId == null || hostPeerId.isEmpty) {
        try {
          final route = await currentRoute();
          if (route.runLocal) {
            _pendingReadChannelIds.clear();
            _pendingReadAgentByChannel.clear();
            _pendingReadAllAgentIds.clear();
            await _savePendingReadPrefs(const {}, const {}, const {});
            if (outboxOpIds.isNotEmpty) {
              await LocalDatabaseService().deletePendingOps(outboxOpIds);
            }
            return;
          }
          hostPeerId = route.hostPeerId;
        } catch (_) {
          await _savePendingReadPrefs(
            _pendingReadChannelIds,
            _pendingReadAgentByChannel,
            _pendingReadAllAgentIds,
          );
          return;
        }
      }
      if (hostPeerId == null || hostPeerId.isEmpty) {
        await _savePendingReadPrefs(
          _pendingReadChannelIds,
          _pendingReadAgentByChannel,
          _pendingReadAllAgentIds,
        );
        return;
      }

      final batchChannels = _pendingReadChannelIds.toList();
      final batchAgentByChannel =
          Map<String, String>.from(_pendingReadAgentByChannel);
      final batchAllAgents = _pendingReadAllAgentIds.toList();
      _pendingReadChannelIds.clear();
      _pendingReadAgentByChannel.clear();
      _pendingReadAllAgentIds.clear();

      try {
        final byAgent = <String, List<String>>{};
        for (final cid in batchChannels) {
          final aid = batchAgentByChannel[cid] ?? '';
          byAgent.putIfAbsent(aid, () => <String>[]).add(cid);
        }
        for (final aid in batchAllAgents) {
          byAgent.putIfAbsent(aid, () => <String>[]);
        }
        for (final entry in byAgent.entries) {
          final aid = entry.key;
          final cids = entry.value;
          final markAll = aid.isNotEmpty && batchAllAgents.contains(aid);
          if (cids.isEmpty && !markAll) continue;
          await _forward(
            hostPeerId: hostPeerId,
            frame: <String, dynamic>{
              'type': readRequestType,
              'op': 'mark_read',
              'channel_id': cids.isNotEmpty ? cids.first : aid,
              if (cids.isNotEmpty) 'channel_ids': cids,
              if (aid.isNotEmpty) 'agent_id': aid,
              if (markAll) 'all_sessions': true,
            },
            onEvent: (_) {},
          ).timeout(const Duration(seconds: 6));
        }
        if (outboxOpIds.isNotEmpty) {
          await LocalDatabaseService().deletePendingOps(outboxOpIds);
        }
        await _savePendingReadPrefs(
          _pendingReadChannelIds,
          _pendingReadAgentByChannel,
          _pendingReadAllAgentIds,
        );
      } catch (_) {
        _pendingReadChannelIds.addAll(batchChannels);
        _pendingReadAgentByChannel.addAll(batchAgentByChannel);
        _pendingReadAllAgentIds.addAll(batchAllAgents);
        await _savePendingReadPrefs(
          _pendingReadChannelIds,
          _pendingReadAgentByChannel,
          _pendingReadAllAgentIds,
        );
      }
    } finally {
      _flushingReads = false;
    }
  }

  Future<void> _savePendingReadPrefs(
    Iterable<String> ids,
    Map<String, String> agentByChannel,
    Iterable<String> allAgentIds,
  ) async {
    final list = ids.where((s) => s.isNotEmpty).toSet().toList();
    final agentList = allAgentIds.where((s) => s.isNotEmpty).toSet().toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (list.isEmpty) {
        await prefs.remove(_pendingReadPrefsKey);
      } else {
        await prefs.setStringList(_pendingReadPrefsKey, list);
      }
      if (agentList.isEmpty) {
        await prefs.remove(_pendingReadAllAgentsPrefsKey);
      } else {
        await prefs.setStringList(_pendingReadAllAgentsPrefsKey, agentList);
      }
    } catch (_) {}
    try {
      final db = LocalDatabaseService();
      for (final cid in list) {
        final aid = agentByChannel[cid] ?? '';
        await db.enqueuePendingOp(
          opId: 'mark_read:ch:$cid',
          kind: 'mark_read',
          targetId: cid,
          payload: <String, dynamic>{
            'channel_id': cid,
            if (aid.isNotEmpty) 'agent_id': aid,
          },
        );
      }
      for (final aid in agentList) {
        await db.enqueuePendingOp(
          opId: 'mark_read:agent:$aid',
          kind: 'mark_read',
          targetId: aid,
          payload: <String, dynamic>{
            'agent_id': aid,
            'all_sessions': true,
          },
        );
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>?> _attachmentRefs({
    required String hostPeerId,
    required List<AttachmentData>? attachments,
    required String agentId,
    required String channelId,
    required String placement,
  }) async {
    if (attachments == null || attachments.isEmpty) return null;
    final refs = <Map<String, dynamic>>[];
    for (final attachment in attachments) {
      if (!attachment.hasBytes) {
        throw StateError('附件没有内容: ${attachment.fileName}');
      }
      if (attachment.exceedsSizeLimit) {
        throw StateError(
          '附件过大（上限 ${AttachmentData.maxSizeBytes ~/ (1024 * 1024)}MB）: '
          '${attachment.fileName}',
        );
      }
      final fileId = await _files.push(
        peerId: hostPeerId,
        attachment: attachment,
        agentId: agentId,
        channelId: channelId,
        placement: placement,
      );
      refs.add(attachment.toPeerRefJson(fileId, stripClientStoreUri: true));
    }
    return refs;
  }

  static Future<void> _answerInteraction({
    required String hostPeerId,
    required Map<String, dynamic> event,
    required Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    Map<String, dynamic>? result;
    try {
      if (onInteractionRequest != null) {
        final raw = event['data'];
        final payload = raw is Map
            ? Map<String, dynamic>.from(raw.cast<String, dynamic>())
            : <String, dynamic>{};
        final interactionId = event['interaction_id'] as String? ?? '';
        final interactionType = event['interaction_type'] as String? ?? '';
        if (hostPeerId.isNotEmpty && interactionId.isNotEmpty) {
          payload['_hub_interaction'] = <String, dynamic>{
            'host_peer_id': hostPeerId,
            'interaction_id': interactionId,
            'interaction_type': interactionType,
            if (event['request_id'] is String) 'turn_id': event['request_id'],
          };
        }
        result = await onInteractionRequest(
          event['agent_id'] as String? ?? '',
          event['agent_name'] as String? ?? '',
          interactionType,
          payload,
        );
      }
    } catch (_) {
      result = null;
    }
    if (result == null || result['_non_blocking'] == true) return;
    await PeerConnectionManager.instance.sendControl(hostPeerId, {
      'type': interactionResponseType,
      'request_id': event['request_id'],
      'interaction_id': event['interaction_id'],
      'result': result,
    });
  }

  bool isWatching(String turnId) => _pending.containsKey(turnId);

  /// 这路会话的回合还在主机上跑。跟进的消息可以先交到主机排队。
  bool isWatchingChannel(String channelId) {
    if (channelId.isEmpty) return false;
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted && pending.channelId == channelId) {
        return true;
      }
    }
    return false;
  }

  /// 同一会话还有回合在跑时，把下一条先放到主机上。
  ///
  /// 返回 true 表示主机只是收下了，还没开始跑。返回 false 表示主机当时
  /// 正好空着，这条已经跑完。
  Future<bool> enqueueDm({
    required String hostPeerId,
    required String requestId,
    required String channelId,
    required String agentId,
    required String Function() content,
    required bool Function() stillQueued,
    required String userId,
    required String userName,
    String? replyToId,
    String? replyQuoteText,
    List<AttachmentData>? attachments,
  }) {
    return _lane(channelId, () async {
      if (!stillQueued()) return true;
      final text = content().trim();
      if (text.isEmpty) return true;
      final refs = await _attachmentRefs(
        hostPeerId: hostPeerId,
        attachments: attachments,
        agentId: agentId,
        channelId: channelId,
        placement: 'dm',
      );
      if (!stillQueued()) return true;
      final deviceInfo = await ClientDeviceInfo.current();
      final pouchId = (await PouchSessionStore.readActive())?.pouchId ?? '';
      final done = await _forward(
        hostPeerId: hostPeerId,
        requestId: requestId,
        channelId: channelId,
        frame: <String, dynamic>{
          'type': dmRequestType,
          if (pouchId.isNotEmpty) 'pouch_id': pouchId,
          'agent_id': agentId,
          'content': text,
          'user_id': userId,
          'user_name': userName,
          'user_message_id': bareMessageId(requestId),
          'channel_id': channelId,
          if (replyToId != null) 'reply_to_id': bareMessageId(replyToId),
          if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
          if (refs != null) 'attachments': refs,
          ...deviceInfo.toWireFields(),
        },
        onEvent: (_) {},
        completeOn: const {'done', 'queued', 'queue_ok', 'start'},
      );
      return done['kind'] == 'queued';
    });
  }

  /// 群里的下一条，同样先落到主机。
  Future<bool> enqueueGroup({
    required String hostPeerId,
    required String requestId,
    required String channelId,
    required String Function() content,
    required bool Function() stillQueued,
    required String userId,
    required String userName,
    List<String> mentionedAgentIds = const [],
    String? replyToId,
    String? replyQuoteText,
    List<AttachmentData>? attachments,
  }) {
    return _lane(channelId, () async {
      if (!stillQueued()) return true;
      final text = content().trim();
      if (text.isEmpty) return true;
      final refs = await _attachmentRefs(
        hostPeerId: hostPeerId,
        attachments: attachments,
        agentId: 'she-builtin-agent-001',
        channelId: channelId,
        placement: 'group',
      );
      if (!stillQueued()) return true;
      final deviceInfo = await ClientDeviceInfo.current();
      final pouchId = (await PouchSessionStore.readActive())?.pouchId ?? '';
      final groupId = channelId.startsWith('group_') ? channelId : '';
      final sessionId =
          groupId.isEmpty ? null : GroupSessionSelection.of(groupId);
      final done = await _forward(
        hostPeerId: hostPeerId,
        requestId: requestId,
        channelId: channelId,
        frame: groupTurnFrame(
          channelId: channelId,
          content: text,
          userId: userId,
          userName: userName,
          deviceInfo: deviceInfo.toWireFields(),
          pouchId: pouchId,
          groupId: groupId,
          sessionId: sessionId,
          userMessageId: requestId,
          mentionedAgentIds: mentionedAgentIds,
          replyToId: replyToId,
          replyQuoteText: replyQuoteText,
          attachmentRefs: refs,
        ),
        onEvent: (_) {},
        completeOn: const {'done', 'queued', 'queue_ok', 'start'},
      );
      return done['kind'] == 'queued';
    });
  }

  /// 手机上改了队列：编辑、删除、调顺序、清空。和入队走同一条车道，避免改到旧文。
  Future<void> mutateQueue({
    required String hostPeerId,
    required String channelId,
    required String op,
    String? itemId,
    String? content,
    int? delta,
  }) {
    return _lane(channelId, () async {
      await _forward(
        hostPeerId: hostPeerId,
        frame: <String, dynamic>{
          'type': queueRequestType,
          'op': op,
          'channel_id': channelId,
          if (itemId != null) 'item_id': itemId,
          if (content != null) 'content': content,
          if (delta != null) 'delta': delta,
        },
        onEvent: (_) {},
      );
    });
  }

  /// 主机裁决回执（`session_ack`）：这条请求已被受理，`started` 或 `queued`。
  /// 旧路径等 `pouch_turn_event kind:queued`，主机已不再发那种帧；这里把
  /// 回执转成在途 turn 认得的 kind，避免 `_forward` 一直干等到超时。
  void onSessionAck(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String? ?? '';
    if (!_pending.containsKey(requestId)) return;
    final disposition = data['disposition'] as String? ?? '';
    if (disposition == 'rejected') {
      onEvent(<String, dynamic>{
        'request_id': requestId,
        'kind': 'error',
        'message': data['message'] as String? ?? '主机会话队列已满',
      });
      return;
    }
    // started / queued 都**不** complete：_forward 要等真正的 done。
    // 旧实现把 queued 转成 kind:'queued'，而它在 completeOn 里，会让排队
    // 消息立刻返回空 buffer、落一条空回复。
    if (disposition == 'queued') {
      _pending[requestId]?.hostQueued = true;
    }
  }

  void onEvent(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String? ?? '';
    final pending = _pending[requestId];
    if (pending == null) return;
    final kind = data['kind'] as String? ?? '';
    if (kind == 'error') {
      _pending.remove(requestId);
      final message = data['message'] as String? ?? '主机回合失败';
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError(message));
      }
      return;
    }
    pending.onEvent(data);
    if (pending.completeOn.contains(kind)) {
      pending.done = data;
      _pending.remove(requestId);
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
  }

  Future<T> _lane<T>(String channelId, Future<T> Function() action) {
    final previous = _lanes[channelId] ?? Future<void>.value();
    late final Future<T> result;
    result = previous.then(
      (_) => action(),
      onError: (Object _, StackTrace __) => action(),
    );
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _lanes[channelId] = settled;
    return result.whenComplete(() {
      if (identical(_lanes[channelId], settled)) {
        _lanes.remove(channelId);
      }
    });
  }

  Future<Map<String, dynamic>> _forward({
    required String hostPeerId,
    required Map<String, dynamic> frame,
    required void Function(Map<String, dynamic> event) onEvent,
    String? requestId,
    String? channelId,
    Set<String> completeOn = const {'done', 'queued', 'queue_ok'},
  }) async {
    final id = requestId ?? _uuid.v4();
    final pending = _PendingTurn(
      onEvent,
      channelId: channelId ?? '',
      completeOn: completeOn,
    );
    _pending[id] = pending;
    frame['request_id'] = id;
    final sent = await PeerConnectionManager.instance.sendControl(
      hostPeerId,
      frame,
      // 切网后旧连接常先断开，connectivity 监听到稳定要 ~800ms 去抖 + 探活。
      // 用户手速快时等不到，主动重连并等一小会儿再交回合。
      waitForReconnect: const Duration(seconds: 6),
    );
    if (!sent) {
      _pending.remove(id);
      throw StateError('无法把回合交给储物袋主机');
    }
    // session_ack(queued) 是异步到达的：hostQueued 可能在 await 期间才置位，
    // 上限不能提前固定。排队标记到位后重挂成 25 小时。
    while (!pending.completer.isCompleted) {
      final limit = pending.hostQueued
          ? const Duration(hours: 25)
          : const Duration(minutes: 30);
      try {
        await pending.completer.future.timeout(limit);
      } on TimeoutException {
        if (pending.completer.isCompleted) break;
        if (pending.hostQueued && limit.inMinutes < 25 * 60) continue;
        _pending.remove(id);
        throw TimeoutException('主机回合超时未收尾', limit);
      }
    }
    return pending.done;
  }
}

String _wireType(MessageType type) {
  switch (type) {
    case MessageType.permissionAudit:
      return 'permission_audit';
    case MessageType.text:
    case MessageType.image:
    case MessageType.file:
    case MessageType.audio:
    case MessageType.system:
      return type.name;
  }
}

class PouchChatReadBody {
  const PouchChatReadBody({this.messages = const [], this.count});

  final List<Message> messages;
  final int? count;

  static Map<String, dynamic> encode({
    List<Message> messages = const [],
    int? count,
    bool compact = false,
  }) =>
      <String, dynamic>{
        'kind': 'done',
        if (count != null) 'count': count,
        'messages': [
          for (final message in messages)
            _wireMessage(message, compact: compact),
        ],
      };

  /// 预览帧去掉思考/工具折叠块。它和正文一样大，首屏不靠它。
  static Map<String, dynamic> _wireMessage(
    Message message, {
    required bool compact,
  }) {
    final json = <String, dynamic>{
      ...message.toJson(),
      'type': _wireType(message.type),
      if (message.replyTo != null) 'reply_to': message.replyTo,
    };
    if (!compact) return json;
    final meta = json['metadata'];
    if (meta is! Map ||
        !(meta.containsKey('progress_content') ||
            meta.containsKey('progress_steps'))) {
      return json;
    }
    final copy = Map<String, dynamic>.from(meta);
    copy.remove('progress_content');
    copy.remove('progress_steps');
    json['metadata'] = copy.isEmpty ? null : copy;
    return json;
  }

  static PouchChatReadBody decode(Map<String, dynamic> done) {
    final raw = done['messages'];
    final messages = <Message>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final json = item.cast<String, dynamic>();
        final base = Message.fromJson(json);
        final reply = json['reply_to'] as String?;
        messages.add(reply == null
            ? base
            : Message(
                id: base.id,
                from: base.from,
                to: base.to,
                channelId: base.channelId,
                type: base.type,
                content: base.content,
                timestampMs: base.timestampMs,
                replyTo: reply,
                metadata: base.metadata,
              ));
      }
    }
    return PouchChatReadBody(
      messages: messages,
      count: (done['count'] as num?)?.toInt(),
    );
  }
}

class PouchInteractionWait {
  PouchInteractionWait._();

  static final _waiting = <String, Completer<Map<String, dynamic>?>>{};

  static Future<Map<String, dynamic>?> wait(String id) {
    final completer = Completer<Map<String, dynamic>?>();
    _waiting[id] = completer;
    return completer.future;
  }

  static void complete(Map<String, dynamic> data) {
    final id = data['interaction_id'] as String? ?? '';
    final completer = _waiting.remove(id);
    if (completer == null || completer.isCompleted) return;
    final result = data['result'];
    completer.complete(
      result is Map ? result.cast<String, dynamic>() : null,
    );
  }
}

class _PendingTurn {
  _PendingTurn(
    this.onEvent, {
    required this.channelId,
    this.completeOn = const {'done', 'queued', 'queue_ok'},
  });

  final void Function(Map<String, dynamic> event) onEvent;
  final String channelId;
  final Set<String> completeOn;
  final Completer<void> completer = Completer<void>();
  Map<String, dynamic> done = const {};
  /// 主机已把这条收进会话队列：排队超过 30 分钟是正常情况（上一轮还没
  /// 跑完），超时上限放宽到 25 小时，避免误判失败后主机又照常执行。
  bool hostQueued = false;
}
