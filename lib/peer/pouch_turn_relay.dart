import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import 'services/peer_connection_manager.dart';

/// 客户端把群编排 / 本机回合交给持有储物袋的主机。
///
/// 主机收到后在本机跑现有的 [ChatService] 路径，再用事件帧把流式结果送回。
class PouchTurnRelay {
  PouchTurnRelay._();

  static final PouchTurnRelay instance = PouchTurnRelay._();

  static const groupRequestType = 'pouch_group_turn';
  static const dmRequestType = 'pouch_dm_turn';
  static const eventType = 'pouch_turn_event';

  final _uuid = const Uuid();
  final _pending = <String, _PendingTurn>{};

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
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
  }) {
    return _forward(
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
      },
      onEvent: (event) {
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
    void Function(String chunk)? onStreamChunk,
  }) {
    final buffer = StringBuffer();
    return _forward(
      hostPeerId: hostPeerId,
      frame: <String, dynamic>{
        'type': dmRequestType,
        'agent_id': agentId,
        'content': content,
        'user_id': userId,
        'user_name': userName,
        if (channelId != null) 'channel_id': channelId,
      },
      onEvent: (event) {
        if (event['kind'] == 'chunk') {
          final chunk = event['chunk'] as String? ?? '';
          buffer.write(chunk);
          onStreamChunk?.call(chunk);
        }
      },
    ).then((_) => buffer.toString());
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
      _pending.remove(requestId);
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
  }

  Future<void> _forward({
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
  }
}

class _PendingTurn {
  _PendingTurn(this.onEvent);

  final void Function(Map<String, dynamic> event) onEvent;
  final Completer<void> completer = Completer<void>();
}
