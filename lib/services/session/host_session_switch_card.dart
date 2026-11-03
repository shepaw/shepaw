import '../chat_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../messaging/chat_history_content.dart';
import 'dm_session_create_service.dart';

/// 主机端建好会话后，把切换卡片挂到来源会话。
///
/// 卡片只是本端的一条 UI 消息：会话本身由主机创建，App 不再本地建会话。
/// 同一张卡片（同一个来源 + 新会话）只插一次，重连时重复推事件也不会刷屏。
Future<bool> attachHostSessionSwitchCard({
  required String channelId,
  required Map<String, dynamic> sessionAction,
  LocalDatabaseService? db,
  void Function(String channelId)? notify,
}) async {
  if (channelId.isEmpty || sessionAction.isEmpty) return false;
  final database = db ?? LocalDatabaseService();
  final notifyUpdate = notify ?? ChatService().notifyChannelUpdate;
  final newId = sessionAction['new_session_id']?.toString() ?? '';
  final id = 'session_switch_${channelId.hashCode.abs()}_${newId.hashCode.abs()}';
  try {
    if (await database.getMessageById(id) != null) return false;
    await database.createMessage(
      id: id,
      channelId: channelId,
      senderId: 'system',
      senderType: 'system',
      senderName: 'system',
      content: '',
      messageType: 'system',
      metadata: {
        DmSessionCreateService.metaActionKey: sessionAction,
        ChatHistoryContent.historyExcludeMetaKey: true,
      },
    );
    await database.markMessageAsRead(id);
    notifyUpdate(channelId);
    return true;
  } catch (e) {
    LoggerService().warning(
      'Failed to attach host session switch card: $e',
      tag: 'HostSession',
    );
    return false;
  }
}
