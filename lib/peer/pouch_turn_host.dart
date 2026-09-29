import '../../services/chat_service.dart';
import '../../services/local_database_service.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import 'services/peer_connection_manager.dart';
import 'pouch_turn_relay.dart';

/// 主机侧：客户端交来的群编排和本机回合，在这台持有储物袋的进程里跑。
class PouchTurnHost {
  PouchTurnHost._();

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
      if (type == PouchTurnRelay.groupRequestType) {
        await _runGroup(data, enqueue);
      } else if (type == PouchTurnRelay.dmRequestType) {
        await _runDm(data, enqueue);
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

  static Future<void> _runGroup(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic>) send,
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
    );
  }

  static Future<void> _runDm(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic>) send,
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
      onStreamChunk: (chunk) {
        send({'kind': 'chunk', 'chunk': chunk});
      },
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final item in raw) item.toString()];
  }
}
