import 'dart:async';

import '../logger_service.dart';
import 'group_event.dart';

/// In-memory recent-event log per channel, plus best-effort workspace
/// persistence via [onPersist] for crash recovery.
///
/// Passive events (step completions …) are recorded here so the next relevant
/// member's context bundle can inject a compact event digest. Active-notify
/// events are recorded too — failure history is just as relevant downstream.
class GroupEventStore {
  GroupEventStore({
    Future<void> Function(GroupEvent event, int seq)? onPersist,
  }) : _onPersist = onPersist;

  static const int _maxPerChannel = 50;

  /// Optional persistence hook (wired by ChatService to GroupWorkspaceService).
  /// Failures are logged and swallowed — never fatal to the caller.
  final Future<void> Function(GroupEvent event, int seq)? _onPersist;

  /// channelId → recent events, oldest first (bounded by [_maxPerChannel]).
  final Map<String, List<GroupEvent>> _recent = {};

  /// Per-channel monotonic sequence for ordering persisted events.
  final Map<String, int> _seq = {};

  /// Most recent [limit] events for [channelId], oldest-first. Never mutates
  /// the caller's list.
  List<GroupEvent> recent(String channelId, {int limit = 5}) {
    final list = _recent[channelId];
    if (list == null || list.isEmpty) return const [];
    if (list.length <= limit) return List.unmodifiable(list);
    return List.unmodifiable(list.sublist(list.length - limit));
  }

  /// 崩溃重启后从工作空间持久化日志回放 [channelId] 的最近事件，恢复上下文
  /// 注入与感知回合所需的内存态。
  ///
  /// 幂等：该频道已有内存事件时跳过（防止同进程内重复回放/追加重复）。
  /// [entries] 需按 seq 升序；超过 [_maxPerChannel] 时只保留尾部。
  void restore(String channelId, List<({int seq, GroupEvent event})> entries) {
    if (entries.isEmpty) return;
    final existing = _recent[channelId];
    if (existing != null && existing.isNotEmpty) return;
    final list = entries.map((e) => e.event).toList();
    if (list.length > _maxPerChannel) {
      list.removeRange(0, list.length - _maxPerChannel);
    }
    _recent[channelId] = list;
    var maxSeq = 0;
    for (final e in entries) {
      if (e.seq > maxSeq) maxSeq = e.seq;
    }
    _seq[channelId] = maxSeq;
  }

  /// Record an event in memory and fire the persistence hook (best-effort).
  void record(GroupEvent event) {
    final list = _recent.putIfAbsent(event.channelId, () => []);
    list.add(event);
    if (list.length > _maxPerChannel) {
      list.removeRange(0, list.length - _maxPerChannel);
    }
    final seq = (_seq[event.channelId] ?? 0) + 1;
    _seq[event.channelId] = seq;

    final persist = _onPersist;
    if (persist != null) {
      unawaited(persist(event, seq).catchError((Object e, StackTrace st) {
        LoggerService().error(
          'group event persist failed for ${event.channelId}: $e',
          tag: 'GroupEventStore',
          error: e,
          stackTrace: st,
        );
      }));
    }
  }
}
