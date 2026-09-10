import 'dart:async';

import '../../models/channel.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import 'event_bus.dart';
import 'perception_scheduler.dart';

/// Notify-only 回合执行器：`(agentId, channelId, events)`。
///
/// [channelId] 为空字符串时由执行方自行解析 DM 频道（如 peer 入站事件不带频道）。
typedef EventNotifyTurnHandler = Future<void> Function(
  String agentId,
  String channelId,
  List<EventEnvelope> events,
);

/// Wires [PerceptionScheduler] to agent notify-only turns (P1+).
class EventPerceptionService {
  EventPerceptionService._();
  static final EventPerceptionService instance = EventPerceptionService._();

  static const _tag = 'EventPerception';

  /// Set by [ChatService] after messaging stack is ready.
  EventNotifyTurnHandler? runNotifyTurn;

  PerceptionScheduler? _boundScheduler;

  void ensureBound(PerceptionScheduler scheduler) {
    if (_boundScheduler == scheduler && scheduler.onSchedule != null) return;
    _boundScheduler = scheduler;
    // 直接绑 _onSchedule（返回 Future）：scheduler 需要 await 它才能把 running
    // 锁覆盖到回合结束。早期版本用 `unawaited(...)` 包一层，会让锁在回合开始
    // 的瞬间就释放，导致 notify-only 回合重叠。
    scheduler.onSchedule = _onSchedule;
  }

  Future<void> _onSchedule(
    String agentId,
    String channelId,
    List<EventEnvelope> events,
  ) async {
    if (events.isEmpty) return;
    final run = runNotifyTurn;
    if (run == null) {
      LoggerService().debug(
        'Event perception skipped (no handler): agent=$agentId types=${events.map((e) => e.type).join(",")}',
        tag: _tag,
      );
      return;
    }
    try {
      await run(agentId, channelId, events);
    } catch (e, st) {
      LoggerService().error(
        'Event perception turn failed: $e',
        tag: _tag,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// 解析 owner ↔ agent 的 1:1 频道；找不到返回 null（调用方降级为仅入 inbox）。
  ///
  /// DM 频道 id 是 uuid（`LocalApiService.createDM`），**不等于** agentId，
  /// 因此必须查库：取成员恰好为 {owner, agent} 的 dm 频道。
  ///
  /// 优先级：普通 DM > 群绑定会话 / She 绑定会话。
  /// 绑定会话（`agents.chat`、群派发为成员自动创建）成员也可能恰好是
  /// {owner, agent}，若直接取首个匹配，感知回合会被写进 agent↔agent 的
  /// 会话频道而非用户与 agent 的单聊。筛选口径与
  /// `ChatService.drainAllMailboxReplies` 一致。
  static Future<String?> resolveDirectChannelId(String agentId) async {
    try {
      final channels = await LocalDatabaseService().getChannelsForAgent(agentId);
      final ownerId = LocalUserIdentity.id;
      Channel? fallback;
      for (final channel in channels) {
        final memberIds = channel.members.map((m) => m.id).toSet();
        if (memberIds.length != 2 || !memberIds.contains(agentId)) continue;
        if (ownerId.isNotEmpty && !memberIds.contains(ownerId)) continue;
        if (!channel.isGroupBoundMemberSession && !channel.isSheBoundSession) {
          return channel.id;
        }
        fallback ??= channel;
      }
      return fallback?.id;
    } catch (e) {
      LoggerService().warning(
        'Failed to resolve DM channel for $agentId',
        tag: _tag,
        error: e,
      );
    }
    return null;
  }
}

/// Bind the given [bus]'s scheduler (defaults to the global one).
void wireEventPerception([EventBus? bus]) {
  EventPerceptionService.instance
      .ensureBound((bus ?? EventBus.instance).perceptionScheduler);
}
