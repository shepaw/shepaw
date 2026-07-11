import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/stream_content_splitter.dart';

void main() {
  group('StreamContentSplitter', () {
    test('diverts collapsible chunks to progress, answer stays separate', () {
      final s = StreamContentSplitter();

      s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Thinking',
        'auto_collapse': true,
      });
      expect(s.onChunk('think...'), '');
      expect(s.progressContent, 'think...');
      expect(s.answerContent, '');

      s.onMetadata({'collapsible': false});
      expect(s.onChunk('Hello'), 'Hello');
      expect(s.answerContent, 'Hello');
      expect(s.progressContent, 'think...');

      final meta = s.finalProgressMetadata();
      expect(meta['progress_content'], 'think...');
      expect(meta['collapsible'], true);
      expect(meta['collapsible_title'], 'Thinking');
    });

    test('does not re-divert when upstream already split', () {
      final s = StreamContentSplitter();
      s.onMetadata({
        'progress_content': 'already folded',
        'collapsible': true,
        'collapsible_title': 'Tool',
      });
      expect(s.alreadySplitUpstream, true);
      expect(s.onChunk('Answer text'), 'Answer text');
      expect(s.progressContent, 'already folded');
      expect(s.answerContent, 'Answer text');
    });

    test('re-enters progress after more tool metadata', () {
      final s = StreamContentSplitter();
      s.onMetadata({'collapsible': true, 'collapsible_title': 'Run'});
      s.onChunk('[in_progress] Run\n');
      s.onMetadata({'collapsible': false});
      s.onChunk('partial answer ');
      s.onMetadata({'collapsible': true, 'collapsible_title': 'Read'});
      expect(s.onChunk('[completed] Read\n'), '');
      s.onMetadata({'collapsible': false});
      expect(s.onChunk('final'), 'final');

      expect(s.progressContent, contains('Run'));
      expect(s.progressContent, contains('Read'));
      expect(s.answerContent, 'partial answer final');
    });

    test('progressMetadataDelta is null until progress exists', () {
      final s = StreamContentSplitter();
      expect(s.progressMetadataDelta(), isNull);

      s.onMetadata({'collapsible': true});
      s.onChunk('x');
      final delta = s.progressMetadataDelta();
      expect(delta?['progress_content'], 'x');
      expect(delta?['collapsible_title'], 'Details');
      expect(delta?['auto_collapse'], isTrue);
    });

    test('respects auto_collapse false and custom title defaults', () {
      final s = StreamContentSplitter();
      final out = s.onMetadata({
        'collapsible': true,
        'auto_collapse': false,
      });
      expect(s.autoCollapse, isFalse);
      s.onChunk('tool');
      final meta = s.finalProgressMetadata();
      expect(meta['auto_collapse'], isFalse);
      expect(meta['collapsible_title'], 'Details');
      expect(out['collapsible'], isTrue);
    });

    test('collapsible false clears whole-message collapsible when no progress',
        () {
      final s = StreamContentSplitter();
      final out = s.onMetadata({'collapsible': false});
      expect(out['collapsible'], isFalse);
    });
  });
}
