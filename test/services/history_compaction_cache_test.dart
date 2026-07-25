import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/session/history_compaction_cache.dart';
import 'package:shepaw/services/session/history_compactor.dart';

Message _msg(String id, String content) {
  return Message(
    id: id,
    content: content,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
    from: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
  );
}

void main() {
  group('HistoryCompactionCacheEntry', () {
    test('matchesExact when window ids and count align', () {
      final older = [_msg('a', '1'), _msg('b', '2'), _msg('c', '3')];
      final entry = HistoryCompactionCacheEntry.fromOlder(
        channelId: 'ch',
        summary: 'sum',
        older: older,
      );
      expect(entry.matchesExact(older), isTrue);
      expect(entry.matchesExact([_msg('a', '1'), _msg('b', '2')]), isFalse);
      expect(
        entry.matchesExact([_msg('a', '1'), _msg('b', '2'), _msg('x', '3')]),
        isFalse,
      );
    });

    test('isPrefixOf when older extends the cached range', () {
      final cachedOlder = [_msg('a', '1'), _msg('b', '2')];
      final entry = HistoryCompactionCacheEntry.fromOlder(
        channelId: 'ch',
        summary: 'old summary',
        older: cachedOlder,
      );
      final extended = [
        ...cachedOlder,
        _msg('c', '3'),
        _msg('d', '4'),
      ];
      expect(entry.isPrefixOf(extended), isTrue);
      expect(entry.isPrefixOf(cachedOlder), isFalse);
      expect(
        entry.isPrefixOf([_msg('z', '1'), _msg('b', '2'), _msg('c', '3')]),
        isFalse,
      );
    });

    test('fromOlder clips long summaries', () {
      final long = 'x' * (HistoryCompactor.defaultSummaryMaxChars + 100);
      final entry = HistoryCompactionCacheEntry.fromOlder(
        channelId: 'ch',
        summary: long,
        older: [_msg('a', '1')],
      );
      expect(
        entry.summary.length,
        HistoryCompactor.defaultSummaryMaxChars + 1, // clipped + ellipsis
      );
      expect(entry.summary.endsWith('…'), isTrue);
    });
  });

  group('HistoryCompactionCacheLogic', () {
    test('incrementalTranscript includes previous summary and delta', () {
      final text = HistoryCompactionCacheLogic.incrementalTranscript(
        previousSummary: 'Alice likes tea.',
        delta: [_msg('n1', 'Also coffee')],
      );
      expect(text, contains('Previous conversation summary'));
      expect(text, contains('Alice likes tea.'));
      expect(text, contains('New turns since that summary'));
      expect(text, contains('Also coffee'));
    });
  });
}
