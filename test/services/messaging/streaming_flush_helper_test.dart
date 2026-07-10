import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/streaming_flush_helper.dart';

void main() {
  group('buildPeerFinalContent', () {
    test('cancel with answer keeps text and appends [Stopped]', () {
      expect(
        buildPeerFinalContent(
          answerContent: 'Hello world',
          progressContent: 'thinking',
          accumulatedContent: 'Hello world',
          resultContent: '[Stopped]',
          wasCancelled: true,
        ),
        'Hello world\n\n[Stopped]',
      );
    });

    test('cancel with progress only still yields [Stopped]', () {
      expect(
        buildPeerFinalContent(
          answerContent: '',
          progressContent: 'Running tool…',
          accumulatedContent: '',
          resultContent: '[Stopped]',
          wasCancelled: true,
        ),
        '[Stopped]',
      );
    });

    test('cancel with no chunks yields [Stopped]', () {
      expect(
        buildPeerFinalContent(
          answerContent: '',
          progressContent: '',
          accumulatedContent: '',
          resultContent: '[Stopped]',
          wasCancelled: true,
        ),
        '[Stopped]',
      );
    });

    test('normal progress-only turn keeps empty content', () {
      expect(
        buildPeerFinalContent(
          answerContent: '',
          progressContent: 'thinking',
          accumulatedContent: '',
          resultContent: '',
          wasCancelled: false,
        ),
        '',
      );
    });

    test('normal answer prefers splitter answer', () {
      expect(
        buildPeerFinalContent(
          answerContent: 'Done',
          progressContent: 'thinking',
          accumulatedContent: 'Done',
          resultContent: 'Done',
          wasCancelled: false,
        ),
        'Done',
      );
    });
  });
}
