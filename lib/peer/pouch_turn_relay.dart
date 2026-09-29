import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/message.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
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

  static const controlTypes = <String>[
    groupRequestType,
    dmRequestType,
    readRequestType,
    interactionResponseType,
    eventType,
  ];

  final _uuid = const Uuid();
  final _pending = <String, _PendingTurn>{};
  final _files = PouchAttachmentClient(
    send: (peerId, frame) =>
        PeerConnectionManager.instance.sendControl(peerId, frame),
  );

  void onFileAck(Map<String, dynamic> data) => _files.onAck(data);

  /// 没有角色文件时在本机跑。读失败抛出，避免客户端悄悄在本地把编排跑起来。
  static Future<PouchTurnRoute> currentRoute() async {
    final root = await StoreService.instance.storeRoot();
    final role = await PouchRoleStore(root).load();
    return PouchTurnRoute.decide(role);
  }

  Future<void> forwardGroup({
    required String hostPeerId,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required List<String> agentIds,
    List<String> mentionedAgentIds = const [],
    String? adminAgentId,
    bool flowMode = false,
    String? replyToId,
    String? replyQuoteText,
    List<AttachmentData>? attachments,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
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
      agentId: adminAgentId ?? (agentIds.isEmpty ? '' : agentIds.first),
      channelId: channelId,
      placement: 'group',
    );
    await _forward(
      hostPeerId: hostPeerId,
      frame: <String, dynamic>{
        'type': groupRequestType,
        'channel_id': channelId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
        'agent_ids': agentIds,
        'mentioned_agent_ids': mentionedAgentIds,
        if (adminAgentId != null) 'admin_agent_id': adminAgentId,
        'flow_mode': flowMode,
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

  /// 把本机 LLM 回合交给主机。返回主机流式拼出的正文。
  Future<String> forwardDm({
    required String hostPeerId,
    required String agentId,
    required String content,
    required String userId,
    required String userName,
    String? channelId,
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
    await _forward(
      hostPeerId: hostPeerId,
      frame: <String, dynamic>{
        'type': dmRequestType,
        'agent_id': agentId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
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
    return buffer.toString();
  }

  /// 向主机要一页消息，或一个条数。本机和远程都从这里进。
  Future<PouchChatReadBody> readChat({
    required String hostPeerId,
    required String op,
    required String channelId,
    int? limit,
    String? beforeCreatedAt,
    String? messageId,
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
    await PeerConnectionManager.instance.sendControl(hostPeerId, {
      'type': interactionResponseType,
      'request_id': event['request_id'],
      'interaction_id': event['interaction_id'],
      'result': result,
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
    if (kind == 'done') {
      pending.done = data;
      _pending.remove(requestId);
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
  }

  Future<Map<String, dynamic>> _forward({
    required String hostPeerId,
    required Map<String, dynamic> frame,
    required void Function(Map<String, dynamic> event) onEvent,
  }) async {
    final requestId = _uuid.v4();
    final pending = _PendingTurn(onEvent);
    _pending[requestId] = pending;
    frame['request_id'] = requestId;
    final sent = await PeerConnectionManager.instance.sendControl(
      hostPeerId,
      frame,
    );
    if (!sent) {
      _pending.remove(requestId);
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
  }) =>
      <String, dynamic>{
        'kind': 'done',
        if (count != null) 'count': count,
        'messages': [
          for (final message in messages)
            <String, dynamic>{
              ...message.toJson(),
              'type': _wireType(message.type),
              if (message.replyTo != null) 'reply_to': message.replyTo,
            },
        ],
      };

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
  _PendingTurn(this.onEvent);

  final void Function(Map<String, dynamic> event) onEvent;
  final Completer<void> completer = Completer<void>();
  Map<String, dynamic> done = const {};
}
