import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// Shared across pumps on purpose: the widget skips its cache when the
/// styleSheet instance changes, and production passes the same one every
/// rebuild (`_getStyleSheet` caches by (isMyMessage, colorScheme)). A fresh
/// instance per pump would defeat the cache regardless of the throttle.
final MarkdownStyleSheet _styleSheet = MarkdownStyleSheet();

/// Hosts one [StableMarkdownBody]; pumping it again with new `data` calls
/// `didUpdateWidget` on the same State, exactly like a streaming chunk does.
Widget host(String data, {bool streaming = true}) => MaterialApp(
      home: Scaffold(
        body: StableMarkdownBody(
          data: data,
          styleSheet: _styleSheet,
          isStreaming: streaming,
        ),
      ),
    );

Future<void> pumpData(
  WidgetTester tester,
  String data, {
  bool streaming = true,
}) =>
    tester.pumpWidget(host(data, streaming: streaming));

/// Rendered markdown text. `findRichText` because [MarkdownBody] renders
/// RichText rather than Text.
Finder renderedText(String text) => find.text(text, findRichText: true);

/// The whole throttle interval, plus a margin so the timer has definitely run.
const Duration pastWindow = Duration(milliseconds: 200);

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

  // The pure helper above only decides; the throttle lives in the State.
  // Regression guard: an earlier version never opened the throttle window on
  // the immediate-parse path, so `timerActive` stayed false forever, the defer
  // branch was unreachable, and every chunk re-parsed the whole reply
  // (O(reply²) per turn). These tests drive the real widget.
  group('StableMarkdownBody throttle (state machine)', () {
    testWidgets('first update renders now, the rest wait for the window',
        (tester) async {
      await pumpData(tester, 'AA');
      expect(renderedText('AA'), findsOneWidget);

      // First update: rendered immediately (TTFT must not regress).
      await pumpData(tester, 'AABB');
      expect(renderedText('AABB'), findsOneWidget);

      // Same window: deferred, so the previous parse is still on screen.
      await pumpData(tester, 'AABBCC');
      expect(renderedText('AABBCC'), findsNothing);
      expect(renderedText('AABB'), findsOneWidget);

      await pumpData(tester, 'AABBCCDD');
      expect(renderedText('AABBCCDD'), findsNothing);

      // Window closes: everything received so far is rendered.
      await tester.pump(pastWindow);
      expect(renderedText('AABBCCDD'), findsOneWidget);
    });

    testWidgets('one re-parse per window, not per chunk', (tester) async {
      await pumpData(tester, 'AA');
      await pumpData(tester, 'AABB'); // immediate, opens the window
      await pumpData(tester, 'AABBCC'); // deferred
      await tester.pump(pastWindow);
      expect(renderedText('AABBCC'), findsOneWidget);

      // A chunk landing right after the flush belongs to the next window.
      await pumpData(tester, 'AABBCCDD');
      expect(renderedText('AABBCCDD'), findsNothing);
      await tester.pump(pastWindow);
      expect(renderedText('AABBCCDD'), findsOneWidget);
    });

    testWidgets('an idle stream renders the next chunk immediately',
        (tester) async {
      await pumpData(tester, 'AA');
      await pumpData(tester, 'AABB'); // immediate, opens the window
      await tester.pump(pastWindow); // window closes with nothing deferred

      // No open window → this chunk must not wait for one.
      await pumpData(tester, 'AABBCC');
      expect(renderedText('AABBCC'), findsOneWidget);
    });

    testWidgets('turn end flushes pending text immediately', (tester) async {
      await pumpData(tester, 'AA');
      await pumpData(tester, 'AABB'); // immediate, opens the window
      await pumpData(tester, 'AABBCC'); // deferred
      expect(renderedText('AABBCC'), findsNothing);

      // isStreaming: false must drop the throttle and render the latest text.
      await pumpData(tester, 'AABBCCDD', streaming: false);
      expect(renderedText('AABBCCDD'), findsOneWidget);
    });

    testWidgets('settled bubbles are never deferred', (tester) async {
      await pumpData(tester, 'AA', streaming: false);
      await pumpData(tester, 'AABB', streaming: false);
      expect(renderedText('AABB'), findsOneWidget);
    });
  });
}
