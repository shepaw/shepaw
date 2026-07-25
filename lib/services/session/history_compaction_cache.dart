import '../../models/message.dart';
import 'history_compactor.dart';

/// Persisted compaction summary for one channel.
class HistoryCompactionCacheEntry {
  final String channelId;
  final String summary;
  final String fromMessageId;
  final String untilMessageId;
  final int coveredCount;
  final int updatedAtMs;

  const HistoryCompactionCacheEntry({
    required this.channelId,
    required this.summary,
    required this.fromMessageId,
    required this.untilMessageId,
    required this.coveredCount,
    required this.updatedAtMs,
  });

  factory HistoryCompactionCacheEntry.fromOlder({
    required String channelId,
    required String summary,
    required List<Message> older,
    int? updatedAtMs,
  }) {
    assert(older.isNotEmpty);
    final clipped = summary.length <= HistoryCompactor.defaultSummaryMaxChars
        ? summary
        : '${summary.substring(0, HistoryCompactor.defaultSummaryMaxChars)}…';
    return HistoryCompactionCacheEntry(
      channelId: channelId,
      summary: clipped,
      fromMessageId: older.first.id,
      untilMessageId: older.last.id,
      coveredCount: older.length,
      updatedAtMs: updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Same older window as when the summary was produced.
  bool matchesExact(List<Message> older) {
    if (older.isEmpty || older.length != coveredCount) return false;
    return older.first.id == fromMessageId && older.last.id == untilMessageId;
  }

  /// Cached range is a contiguous prefix of [older] (new turns appended).
  bool isPrefixOf(List<Message> older) {
    if (coveredCount <= 0 || older.length <= coveredCount) return false;
    if (older.first.id != fromMessageId) return false;
    return older[coveredCount - 1].id == untilMessageId;
  }

  Map<String, dynamic> toMap() => {
        'channel_id': channelId,
        'summary': summary,
        'from_message_id': fromMessageId,
        'until_message_id': untilMessageId,
        'covered_count': coveredCount,
        'updated_at': updatedAtMs,
      };

  factory HistoryCompactionCacheEntry.fromMap(Map<String, dynamic> map) {
    return HistoryCompactionCacheEntry(
      channelId: map['channel_id'] as String,
      summary: map['summary'] as String? ?? '',
      fromMessageId: map['from_message_id'] as String? ?? '',
      untilMessageId: map['until_message_id'] as String? ?? '',
      coveredCount: map['covered_count'] as int? ?? 0,
      updatedAtMs: map['updated_at'] as int? ?? 0,
    );
  }
}

/// Pure helpers for deciding how to use a cache entry (unit-tested).
class HistoryCompactionCacheLogic {
  HistoryCompactionCacheLogic._();

  /// Build summarizer input for a prefix extension (reuse prior summary + delta).
  static String incrementalTranscript({
    required String previousSummary,
    required List<Message> delta,
  }) {
    final deltaText = HistoryCompactor.buildTranscript(delta);
    return '''
Previous conversation summary:
$previousSummary

New turns since that summary:
$deltaText
''';
  }
}
