import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  group('shouldParseMarkdownNow', () {
    test('no change and no pending work → never parse', () {
      expect(
        shouldParseMarkdownNow(
          isStreaming: true,
          dataChanged: false,
          pendingData: false,
          timerActive: false,
        ),
        isFalse,
      );
      expect(
        shouldParseMarkdownNow(
          isStreaming: false,
          dataChanged: false,
          pendingData: false,
          timerActive: false,
        ),
        isFalse,
      );
    });

    test('pending deferred work → only parse when the timer fired', () {
      // Timer still active: keep deferring.
      expect(
        shouldParseMarkdownNow(
          isStreaming: true,
          dataChanged: false,
          pendingData: true,
          timerActive: true,
        ),
        isFalse,
      );
      // Timer fired (frame callback re-entered with pending data): parse.
      expect(
        shouldParseMarkdownNow(
          isStreaming: true,
          dataChanged: false,
          pendingData: true,
          timerActive: false,
        ),
        isTrue,
      );
    });

    test('streaming: parse the first chunk immediately, defer the rest', () {
      expect(
        shouldParseMarkdownNow(
          isStreaming: true,
          dataChanged: true,
          pendingData: false,
          timerActive: false,
        ),
        isTrue,
      );
      expect(
        shouldParseMarkdownNow(
          isStreaming: true,
          dataChanged: true,
          pendingData: true,
          timerActive: true,
        ),
        isFalse,
      );
    });

    test('not streaming → parse immediately (flush semantics)', () {
      expect(
        shouldParseMarkdownNow(
          isStreaming: false,
          dataChanged: true,
          pendingData: false,
          timerActive: false,
        ),
        isTrue,
      );
      // Settled bubble flush overrides any pending throttle state.
      expect(
        shouldParseMarkdownNow(
          isStreaming: false,
          dataChanged: true,
          pendingData: true,
          timerActive: true,
        ),
        isTrue,
      );
    });
  });
}
