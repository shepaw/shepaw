import 'dart:async';

import 'package:flutter/foundation.dart';

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

  /// L16: 内存事件缓存覆盖的频道数上限。每频道列表已截断到 [_maxPerChannel]，
  /// 但频道键本身随新建群会话无限增长——超限时按插入序淘汰最旧频道（事件已
  /// 落盘 workspace，崩溃恢复可回放，内存里只留热频道）。
  static const int _maxChannels = 100;

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
    _evictIfNeeded(event.channelId);
    final seq = (_seq[event.channelId] ?? 0) + 1;
    _seq[event.channelId] = seq;

    final persist = _onPersist;
    if (persist != null) {
      // L18: 防御同步抛错——persist 若在返回 Future 前同步 throw（非 async
      // 接线），`.catchError` 接不到；显式 try/catch 兜底，绝不波及调用方。
      try {
        unawaited(persist(event, seq).catchError((Object e, StackTrace st) {
          LoggerService().error(
            'group event persist failed for ${event.channelId}: $e',
            tag: 'GroupEventStore',
            error: e,
            stackTrace: st,
          );
        }));
      } catch (e, st) {
        LoggerService().error(
          'group event persist threw synchronously for ${event.channelId}: $e',
          tag: 'GroupEventStore',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  /// 当前覆盖的频道数（L16 上限断言用）。
  @visibleForTesting
  int get channelCountForTest => _recent.length;

  /// 频道键超限时按插入序淘汰最旧频道（Map 保持插入序，keys.first 即最旧）。
  void _evictIfNeeded(String activeChannelId) {
    while (_recent.length > _maxChannels) {
      final oldest = _recent.keys.first;
      _recent.remove(oldest);
      _seq.remove(oldest);
      if (oldest == activeChannelId) {
        // 刚插入的频道被淘汰说明上限小于 1——防御性停止，避免死循环。
        break;
      }
    }
  }
}
