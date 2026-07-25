import '../../models/message.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import 'history_compaction_cache.dart';
import 'history_compactor.dart';

/// Loads / stores channel compaction summaries and obtains a summary for
/// [older] with exact-hit or incremental reuse when possible.
class HistoryCompactionCacheService {
  HistoryCompactionCacheService._();

  static final _db = LocalDatabaseService();

  /// Return a summary for [older], using cache when possible.
  ///
  /// [summarize] runs an LLM call on the provided transcript.
  static Future<String> obtainSummary({
    required String channelId,
    required List<Message> older,
    required Future<String> Function(String transcript) summarize,
  }) async {
    if (older.isEmpty) return '';

    HistoryCompactionCacheEntry? cached;
    try {
      cached = await _db.getHistoryCompactionCache(channelId);
    } catch (e) {
      LoggerService().warning(
        'History compaction cache read failed: $e',
        tag: 'HistoryCompactionCache',
      );
    }

    if (cached != null && cached.summary.isNotEmpty) {
      if (cached.matchesExact(older)) {
        LoggerService().info(
          'Compaction cache hit (exact) for $channelId '
          '(${cached.coveredCount} msgs)',
          tag: 'HistoryCompactionCache',
        );
        return cached.summary;
      }

      if (cached.isPrefixOf(older)) {
        final delta = older.sublist(cached.coveredCount);
        LoggerService().info(
          'Compaction cache incremental for $channelId '
          '(+${delta.length} msgs after ${cached.coveredCount})',
          tag: 'HistoryCompactionCache',
        );
        final transcript = HistoryCompactionCacheLogic.incrementalTranscript(
          previousSummary: cached.summary,
          delta: delta,
        );
        final summary = await summarize(transcript);
        await _store(channelId, summary, older);
        return summary;
      }
    }

    final transcript = HistoryCompactor.buildTranscript(older);
    final summary = await summarize(transcript);
    await _store(channelId, summary, older);
    return summary;
  }

  static Future<void> _store(
    String channelId,
    String summary,
    List<Message> older,
  ) async {
    if (summary.isEmpty || older.isEmpty) return;
    try {
      await _db.upsertHistoryCompactionCache(
        HistoryCompactionCacheEntry.fromOlder(
          channelId: channelId,
          summary: summary,
          older: older,
        ),
      );
    } catch (e) {
      LoggerService().warning(
        'History compaction cache write failed: $e',
        tag: 'HistoryCompactionCache',
      );
    }
  }
}
