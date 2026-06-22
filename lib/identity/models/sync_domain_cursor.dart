import 'sync_event.dart';

/// 分域同步游标（wall_time_ms + event_id），解决同毫秒分页丢事件。
class SyncDomainCursor {
  final int wallTimeMs;
  final String lastEventId;

  const SyncDomainCursor({required this.wallTimeMs, this.lastEventId = ''});

  static const zero = SyncDomainCursor(wallTimeMs: 0);

  static SyncDomainCursor parse(String? raw) {
    if (raw == null || raw.isEmpty) return zero;
    final pipe = raw.indexOf('|');
    if (pipe < 0) {
      return SyncDomainCursor(wallTimeMs: int.tryParse(raw) ?? 0);
    }
    return SyncDomainCursor(
      wallTimeMs: int.tryParse(raw.substring(0, pipe)) ?? 0,
      lastEventId: raw.substring(pipe + 1),
    );
  }

  String serialize() => '$wallTimeMs|$lastEventId';

  static bool isEventAfter(SyncEvent event, SyncDomainCursor cursor) {
    if (event.wallTimeMs > cursor.wallTimeMs) return true;
    if (event.wallTimeMs < cursor.wallTimeMs) return false;
    if (cursor.lastEventId.isEmpty) return true;
    return event.eventId.compareTo(cursor.lastEventId) > 0;
  }

  SyncDomainCursor advance(SyncEvent event) {
    if (isEventAfter(event, this)) {
      return SyncDomainCursor(
        wallTimeMs: event.wallTimeMs,
        lastEventId: event.eventId,
      );
    }
    return this;
  }

  SyncDomainCursor advanceAll(Iterable<SyncEvent> events) {
    var c = this;
    for (final e in events) {
      c = c.advance(e);
    }
    return c;
  }
}
