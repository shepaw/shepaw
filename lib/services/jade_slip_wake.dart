import '../models/jade_slip.dart';
import '../service_locator.dart';
import 'chat_service.dart';
import 'local_user_identity.dart';
import 'logger_service.dart';
import 'remote_agent_service.dart';

/// 玉简被改派或退回时，给干活的那条会话发一条短引用，让对方现读。
class JadeSlipWake {
  static Future<void> notify(
    JadeSlip slip,
    String reason, {
    JadeSlipItem? item,
  }) async {
    if (!getIt.isRegistered<ChatService>() ||
        !getIt.isRegistered<RemoteAgentService>()) {
      return;
    }
    final ids = <String>{
      if (item != null && item.actorId.isNotEmpty) item.actorId,
      if (item != null && item.assigneeAgentId.isNotEmpty)
        item.assigneeAgentId,
      if (slip.assigneeAgentId.isNotEmpty) slip.assigneeAgentId,
    }..removeWhere(
        (id) => id.isEmpty || id == 'user' || id == LocalUserIdentity.id,
      );
    if (ids.isEmpty) return;
    final chat = getIt<ChatService>();
    final agents = getIt<RemoteAgentService>();
    final text =
        '玉简「${slip.title}」（id=${slip.id}）$reason。待办 ${slip.openItems.length} 项。'
        '请 shepaw slip get --id ${slip.id}';
    for (final id in ids) {
      try {
        final agent = await agents.getAgentById(id);
        if (agent == null) continue;
        final session = item?.sessionId.trim() ?? '';
        final channel = session.isNotEmpty
            ? session
            : await chat.getLatestActiveChannelId(LocalUserIdentity.id, id);
        if (channel == null || channel.isEmpty) continue;
        await chat.sendMessageToAgent(
          content: text,
          agent: agent,
          userId: LocalUserIdentity.id,
          userName: LocalUserIdentity.displayName,
          channelId: channel,
        );
      } catch (e) {
        LoggerService().warning('jade slip wake $id failed: $e', tag: 'JadeSlip', error: e);
      }
    }
  }
}
