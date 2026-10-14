import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/message.dart';
import '../../storage/pouch_login.dart';
import '../../storage/pouch_role.dart';
import '../../storage/pouch_session.dart';
import 'pouch_attachment.dart';
import 'services/peer_connection_manager.dart';

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

  final _uuid = const Uuid();
  final _pending = <String, _PendingTurn>{};
  final _lanes = <String, Future<void>>{};
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

  Future<void> forwardGroup({
    required String hostPeerId,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
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
  }) async {
    final refs = await _attachmentRefs(
      hostPeerId: hostPeerId,
      attachments: attachments,
      agentId: 'she-builtin-agent-001',
      channelId: channelId,
      placement: 'group',
    );
    await _forward(
      hostPeerId: hostPeerId,
      channelId: channelId,
      frame: <String, dynamic>{
        'type': groupRequestType,
        'channel_id': channelId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
        'mentioned_agent_ids': mentionedAgentIds,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
        if (refs != null) 'attachments': refs,
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
    List<AttachmentData>? attachments,
    void Function(String chunk)? onStreamChunk,
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
    final done = await _forward(
      hostPeerId: hostPeerId,
      channelId: channelId,
      frame: <String, dynamic>{
        'type': dmRequestType,
        'agent_id': agentId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
        if (userMessageId != null) 'user_message_id': userMessageId,
        if (channelId != null) 'channel_id': channelId,
        if (refs != null) 'attachments': refs,
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
    final done = await _forward(
      hostPeerId: hostPeerId,
      frame: <String, dynamic>{
        'type': readRequestType,
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
        result = await onInteractionRequest(
          event['agent_id'] as String? ?? '',
          event['agent_name'] as String? ?? '',
          event['interaction_type'] as String? ?? '',
          raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{},
        );
      }
    } catch (_) {
      result = null;
    }
    if (result == null) return;
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
      final done = await _forward(
        hostPeerId: hostPeerId,
        requestId: requestId,
        channelId: channelId,
        frame: <String, dynamic>{
          'type': dmRequestType,
          'agent_id': agentId,
          'content': text,
          'user_id': userId,
          'user_name': userName,
          'user_message_id': requestId,
          'channel_id': channelId,
          if (replyToId != null) 'reply_to_id': replyToId,
          if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
          if (refs != null) 'attachments': refs,
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
      final done = await _forward(
        hostPeerId: hostPeerId,
        requestId: requestId,
        channelId: channelId,
        frame: <String, dynamic>{
          'type': groupRequestType,
          'channel_id': channelId,
          'content': text,
          'user_id': userId,
          'user_name': userName,
          'user_message_id': requestId,
          'mentioned_agent_ids': mentionedAgentIds,
          if (replyToId != null) 'reply_to_id': replyToId,
          if (replyQuoteText != null) 'reply_quote_text': replyQuoteText,
          if (refs != null) 'attachments': refs,
        },
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
    );
    if (!sent) {
      _pending.remove(id);
      throw StateError('无法把回合交给储物袋主机');
    }
    await pending.completer.future;
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
    if (meta is! Map || !meta.containsKey('progress_content')) return json;
    final copy = Map<String, dynamic>.from(meta);
    copy.remove('progress_content');
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
}
