import '../../services/chat_service.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import 'services/peer_connection_manager.dart';
import 'pouch_turn_relay.dart';

/// 主机侧只回答聊天记录。单聊和群回合在 Hub 上跑。
class PouchTurnHost {
  PouchTurnHost._();

  static void onInteractionResponse(Map<String, dynamic> data) {
    PouchInteractionWait.complete(data);
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

    final type = data['type'] as String? ?? '';
    if (type == PouchTurnRelay.groupRequestType ||
        type == PouchTurnRelay.dmRequestType) {
      await send({'kind': 'error', 'message': '回合在 Hub 上跑，这台设备不再编排。'});
      return;
    }
    if (type == PouchTurnRelay.readRequestType) {
      await _runRead(data, send);
      return;
    }
    await send({'kind': 'error', 'message': '未知的储物袋回合'});
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
}
