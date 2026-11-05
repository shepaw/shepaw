import '../chat_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../messaging/chat_history_content.dart';
import 'dm_session_create_service.dart';

/// 与 `peer_agent_client_service.dart` 的 `kSyncedPeerSessionPrefix` 保持一致。
/// 这里不 import 那个服务，避免和它形成循环依赖。
const _syncedPeerSessionPrefix = 'psess_';

/// 主机上的会话 id 换算成本地频道 id。
///
/// 主机同步过来的新会话在 App 里是 `psess_<主机id>`；App 自己建过的旧会话
/// 沿用裸 id。来源会话（当前正在看的）本地一定已经存在。
Future<String> localChannelIdForHostSession(
  LocalDatabaseService db,
  String hostSessionId,
) async {
  if (hostSessionId.isEmpty) return '';
  if (await db.getChannelById(hostSessionId) != null) return hostSessionId;
  return '$_syncedPeerSessionPrefix$hostSessionId';
}

/// 主机端建好会话后，把切换卡片挂到来源会话。
///
/// 卡片只是本端的一条 UI 消息：会话本身由主机创建，App 不再本地建会话。
/// 事件重放时不要把用户已经删掉的卡片插回来：只认十分钟内产生的动作。
Future<bool> attachHostSessionSwitchCard({
  required String channelId,
  required Map<String, dynamic> sessionAction,
  LocalDatabaseService? db,
  void Function(String channelId)? notify,
}) async {
  if (channelId.isEmpty || sessionAction.isEmpty) return false;
  final createdAt = sessionAction['created_at_ms'];
  if (createdAt is int &&
      DateTime.now().millisecondsSinceEpoch - createdAt > 600000) {
    return false;
  }
  final database = db ?? LocalDatabaseService();
  final notifyUpdate = notify ?? ChatService().notifyChannelUpdate;
  final action = Map<String, dynamic>.from(sessionAction);
  final isGroup = action['kind'] == 'group';
  final hostNewId = action['new_session_id']?.toString() ?? '';
  // 群会话不是独立频道，卡片按钮要的是主机会话 id（用来选中它）；私聊则要
  // 换算成本地频道 id，否则会打开一个不存在的空频道。
  if (!isGroup && hostNewId.isNotEmpty) {
    action['host_session_id'] = hostNewId;
    action['new_session_id'] =
        await localChannelIdForHostSession(database, hostNewId);
  }
  final sourceLocal =
      await localChannelIdForHostSession(database, channelId);
  action['source_channel_id'] = sourceLocal;
  final id =
      'session_switch_${sourceLocal.hashCode.abs()}_${hostNewId.hashCode.abs()}';
  try {
    if (await database.getMessageById(id) != null) return false;
    await database.createMessage(
      id: id,
      channelId: sourceLocal,
      senderId: 'system',
      senderType: 'system',
      senderName: 'system',
      content: '',
      messageType: 'system',
      metadata: {
        DmSessionCreateService.metaActionKey: action,
        ChatHistoryContent.historyExcludeMetaKey: true,
      },
    );
    await database.markMessageAsRead(id);
    notifyUpdate(sourceLocal);
    return true;
  } catch (e) {
    LoggerService().warning(
      'Failed to attach host session switch card: $e',
      tag: 'HostSession',
    );
    return false;
  }
}
