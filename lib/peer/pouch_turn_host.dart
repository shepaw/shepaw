import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/store_attachment_ref.dart';
import '../../services/chat_service.dart';
import '../../services/local_database_service.dart';
import '../../services/messaging/message_implicit_prompt.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import 'pouch_attachment.dart';
import 'services/peer_connection_manager.dart';
import 'pouch_turn_relay.dart';

/// 主机侧：客户端交来的群编排和本机回合，在这台持有储物袋的进程里跑。
class PouchTurnHost {
  PouchTurnHost._();

  static const _uuid = Uuid();

  static void onInteractionResponse(Map<String, dynamic> data) {
    PouchInteractionWait.complete(data);
  }

  static Future<Map<String, dynamic>?> _ask(
    Future<void> Function(Map<String, dynamic>) send, {
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
  }) async {
    final id = _uuid.v4();
    final pending = PouchInteractionWait.wait(id);
    await send({
      'kind': 'interaction',
      'interaction_id': id,
      'agent_id': agentId,
      'agent_name': agentName,
      'interaction_type': interactionType,
      'data': data,
    });
    try {
      return await pending.timeout(const Duration(minutes: 30));
    } on TimeoutException {
      PouchInteractionWait.complete({'interaction_id': id});
      return null;
    }
  }

  static Future<void> handle(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    Future<void> send(Map<String, dynamic> event) {
      return PeerConnectionManager.instance.sendControl(peerId, {
        'type': PouchTurnRelay.eventType,
        'request_id': requestId,
        ...event,
      });
    }

    final role = await PouchRoleStore(
      await StoreService.instance.storeRoot(),
    ).load();
    if (!role.isHost) {
      await send({'kind': 'error', 'message': '这台设备不是储物袋主机'});
      return;
    }

    var tail = Future<void>.value();
    Future<void> enqueue(Map<String, dynamic> event) {
      tail = tail.then((_) => send(event));
      return tail;
    }

    try {
      final type = data['type'] as String? ?? '';
      if (type == PouchTurnRelay.groupRequestType ||
          type == PouchTurnRelay.dmRequestType) {
        final attachments = await PouchAttachmentDesk.instance.take(
          peerId: peerId,
          raw: data['attachments'],
          read: _readStored,
        );
        final channelId = data['channel_id'] as String? ?? '';
        if (attachments != null && channelId.isNotEmpty) {
          await _persistAttachmentMessages(
            channelId: channelId,
            userId: data['user_id'] as String? ?? '',
            userName: data['user_name'] as String? ?? '',
            attachments: attachments,
          );
        }
        if (type == PouchTurnRelay.groupRequestType) {
          await _runGroup(data, enqueue, attachments);
        } else {
          await _runDm(data, enqueue, attachments);
        }
      } else if (type == PouchTurnRelay.readRequestType) {
        await tail;
        await _runRead(data, send);
        return;
      } else {
        await send({'kind': 'error', 'message': '未知的储物袋回合'});
        return;
      }
      await tail;
      await send({'kind': 'done'});
    } catch (e) {
      await tail;
      await send({'kind': 'error', 'message': '$e'});
    }
  }

  static Future<Uint8List?> _readStored(String storeUri) async {
    final file = await StoreAttachmentRef.fileFromStoreUri(storeUri);
    if (file == null) return null;
    return file.readAsBytes();
  }

  static Future<void> _persistAttachmentMessages({
    required String channelId,
    required String userId,
    required String userName,
    required List<AttachmentData> attachments,
  }) async {
    final db = LocalDatabaseService();
    for (final attachment in attachments) {
      final storeUri = attachment.extraMetadata?['store_uri'] as String?;
      if (storeUri == null || storeUri.isEmpty) continue;
      final messageType = switch (attachment.semanticType) {
        'image' => 'image',
        'audio' => 'audio',
        _ => 'file',
      };
      final metadata = <String, dynamic>{
        'store_uri': storeUri,
        'name': attachment.fileName,
        'type': attachment.semanticType,
        'size': attachment.sizeBytes,
        if (attachment.fileId != null) 'file_id': attachment.fileId,
      };
      final extra = attachment.extraMetadata;
      if (extra != null) {
        for (final entry in extra.entries) {
          if (entry.key == 'store_uri' ||
              entry.key == MessageImplicitPrompt.metaKey ||
              entry.key == MessageImplicitPrompt.urisMetaKey) {
            continue;
          }
          metadata[entry.key] = entry.value;
        }
      }
      final hint = MessageImplicitPrompt.renderStoreReadHint([storeUri]);
      MessageImplicitPrompt.putInMetadata(
        metadata,
        hint: hint,
        uris: [storeUri],
      );
      await db.createMessage(
        id: _uuid.v4(),
        channelId: channelId,
        senderId: userId,
        senderType: 'user',
        senderName: userName,
        content: attachment.textDescription,
        messageType: messageType,
        metadata: metadata,
      );
    }
  }

  static Future<void> _runGroup(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic>) send,
    List<AttachmentData>? attachments,
  ) {
    final agentIds = _stringList(data['agent_ids']);
    final mentioned = _stringList(data['mentioned_agent_ids']);
    return ChatService().sendMessageToGroup(
      channelId: data['channel_id'] as String? ?? '',
      content: data['content'] as String? ?? '',
      userId: data['user_id'] as String? ?? '',
      userName: data['user_name'] as String? ?? '',
      agentIds: agentIds,
      mentionedAgentIds: mentioned,
      adminAgentId: data['admin_agent_id'] as String?,
      flowMode: data['flow_mode'] == true,
      replyToId: data['reply_to_id'] as String?,
      replyQuoteText: data['reply_quote_text'] as String?,
      attachments: attachments,
      onAgentStart: (agentId, agentName) {
        send({
          'kind': 'start',
          'agent_id': agentId,
          'agent_name': agentName,
        });
      },
      onStreamChunk: (agentId, agentName, chunk) {
        send({
          'kind': 'chunk',
          'agent_id': agentId,
          'agent_name': agentName,
          'chunk': chunk,
        });
      },
      onAgentDone: (agentId, agentName, skipped) {
        send({
          'kind': 'agent_done',
          'agent_id': agentId,
          'agent_name': agentName,
          'skipped': skipped,
        });
      },
      onInteractionRequest: (agentId, agentName, interactionType, data) {
        return _ask(
          send,
          agentId: agentId,
          agentName: agentName,
          interactionType: interactionType,
          data: data,
        );
      },
    );
  }

  static Future<void> _runDm(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic>) send,
    List<AttachmentData>? attachments,
  ) async {
    final agentId = data['agent_id'] as String? ?? '';
    final agent = await LocalDatabaseService().getRemoteAgentById(agentId);
    if (agent == null) {
      throw StateError('主机上没有这个 Agent');
    }
    await ChatService().sendMessageToAgent(
      content: data['content'] as String? ?? '',
      agent: agent,
      userId: data['user_id'] as String? ?? '',
      userName: data['user_name'] as String? ?? '',
      channelId: data['channel_id'] as String?,
      attachments: attachments,
      onStreamChunk: (chunk) {
        send({'kind': 'chunk', 'chunk': chunk});
      },
      onOsToolConfirmation: (toolName, args, risk) async {
        final result = await _ask(
          send,
          agentId: agent.id,
          agentName: agent.name,
          interactionType: 'os_tool',
          data: {
            'tool_name': toolName,
            'args': args,
            'risk': risk.name,
          },
        );
        return result?['approved'] == true;
      },
    );
  }

  static Future<void> _runRead(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic> event) send,
  ) async {
    final channelId = data['channel_id'] as String? ?? '';
    final limit = (data['limit'] as num?)?.toInt() ?? 100;
    final op = data['op'] as String? ?? 'messages';
    final chat = ChatService();
    if (op == 'count') {
      final count = await chat.countChannelMessages(channelId);
      await send(PouchChatReadBody.encode(count: count));
      return;
    }
    if (op == 'older') {
      final before = data['before_created_at'] as String? ?? '';
      final messages = await chat.loadOlderChannelMessages(
        channelId,
        beforeCreatedAt: before,
        limit: limit,
      );
      await send(PouchChatReadBody.encode(messages: messages));
      return;
    }
    if (op == 'including') {
      final messages = await chat.loadChannelMessagesIncluding(
        channelId,
        data['message_id'] as String? ?? '',
        paddingAfter: limit,
      );
      await send(PouchChatReadBody.encode(messages: messages));
      return;
    }
    if (op == 'one') {
      final message =
          await chat.getMessageById(data['message_id'] as String? ?? '');
      await send(PouchChatReadBody.encode(
        messages: message == null ? const [] : [message],
      ));
      return;
    }
    final messages = await chat.loadChannelMessages(channelId, limit: limit);
    await send(PouchChatReadBody.encode(messages: messages));
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final item in raw) item.toString()];
  }
}
