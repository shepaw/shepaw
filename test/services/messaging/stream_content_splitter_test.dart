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
  });
}
