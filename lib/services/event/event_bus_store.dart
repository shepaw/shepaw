import 'event_envelope.dart';

/// In-memory global event log + monotonic seq (P0).
class EventBusStore {
  int _seq = 0;
  final List<EventEnvelope> _log = [];

  /// dedupeKey → original event id, expires at wall time ms.
  final Map<String, _DedupeEntry> _dedupeWindow = {};
  static const dedupeWindowMs = 60000;

  /// 内存日志上限（P0 无落库）：群每个 step/round 都会投影一条且 payload 内嵌
  /// 整份 GroupEvent JSON，长会话必须裁剪，否则单调增长。
  static const defaultMaxLogEntries = 1000;

  final int maxLogEntries;

  EventBusStore({int? maxLogEntries})
      : maxLogEntries = maxLogEntries ?? defaultMaxLogEntries;

  int get currentSeq => _seq;

  int nextSeq() => ++_seq;

  void append(EventEnvelope envelope) {
    _log.add(envelope);
    if (_log.length > maxLogEntries) {
      _log.removeRange(0, _log.length - maxLogEntries);
    }
  }

  List<EventEnvelope> get log => List.unmodifiable(_log);

  /// Returns existing event id if [dedupeKey] was seen within the window.
  String? recentDedupeOriginalId(String dedupeKey) {
    _pruneDedupe();
    return _dedupeWindow[dedupeKey]?.eventId;
  }

  void recordDedupe(String dedupeKey, String eventId) {
    _pruneDedupe();
    _dedupeWindow[dedupeKey] = _DedupeEntry(
      eventId: eventId,
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + dedupeWindowMs,
    );
  }

  EventEnvelope? findById(String id) {
    for (final e in _log.reversed) {
      if (e.id == id) return e;
    }
    return null;
  }

  void _pruneDedupe() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _dedupeWindow.removeWhere((_, v) => v.expiresAtMs <= now);
  }

  void reset() {
    _seq = 0;
    _log.clear();
    _dedupeWindow.clear();
  }
}

class _DedupeEntry {
  final String eventId;
  final int expiresAtMs;

  _DedupeEntry({required this.eventId, required this.expiresAtMs});
}
