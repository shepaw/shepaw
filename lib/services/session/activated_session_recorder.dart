import '../../service_locator.dart' show getIt;
import '../local_database_service.dart';
import 'last_activated_session_store.dart';

/// 人工点开一条已经在库里的会话时，补记「对话入口」指针。
///
/// 所有会话点选（抽屉行 / 新建 / 分叉 / 复制 / 搜索命中 / 会话切换卡 / 通知
/// 深链）都收敛到这里：只认本 agent 的普通 DM 会话 —— 群会话 / 群成员中转
/// / She 中转都不是会话列表里 agent 行的落点，写进去会把一条本来有效的指针
/// 覆盖掉。频道还没同步过来时也不写，读侧会按活跃时间兜底。
///
/// 参考 `ChatNavigationService.openChannel`（深链）与
/// `ChatScreen._rememberActivatedSession`（会话点选），两处都调本函数。
Future<void> rememberActivatedDmChannel(
  String channelId, {
  String? agentId,
}) async {
  if (channelId.isEmpty) return;
  if (!getIt.isRegistered<LastActivatedSessionStore>()) return;
  try {
    final db = getIt.isRegistered<LocalDatabaseService>()
        ? getIt<LocalDatabaseService>()
        : LocalDatabaseService();
    final channel = await db.getChannelById(channelId);
    if (channel == null ||
        channel.isGroup ||
        channel.isGroupBoundMemberSession ||
        channel.isSheBoundSession) {
      return;
    }
    final explicit = agentId?.trim() ?? '';
    // 调用方通常已经知道 agent（跨 agent 复制会话时尤其重要）；否则从频道
    // 成员里解析，兼容只用 channelId 打开的聊天页（widget.agentId 为空）。
    final resolved = explicit.isNotEmpty && channel.memberIds.contains(explicit)
        ? explicit
        : (channel.agentIds.isNotEmpty ? channel.agentIds.first : null);
    if (resolved == null || resolved.isEmpty) return;
    await getIt<LastActivatedSessionStore>().remember(
      LastActivatedSessionStore.agentKey(resolved),
      channelId,
    );
  } catch (_) {
    // 记不上只是丢掉「回到上次那条」的便利，不影响打开会话本身。
  }
}
