import 'event_envelope.dart';

/// In-memory global event log + monotonic seq (P0).
class EventBusStore {
  int _seq = 0;
  final List<EventEnvelope> _log = [];

  /// dedupeKey → original event id, expires at wall time ms.
  final Map<String, _DedupeEntry> _dedupeWindow = {};
  static const dedupeWindowMs = 60000;

  int get currentSeq => _seq;

  int nextSeq() => ++_seq;

  void append(EventEnvelope envelope) {
    _log.add(envelope);
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
