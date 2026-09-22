import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/chat/session_preview_entry.dart';

void main() {
  test('switching sessions only marks the left and entered rows stale', () {
    final previews = {
      'a': SessionPreviewEntry()..stale = false,
      'b': SessionPreviewEntry()..stale = false,
      'c': SessionPreviewEntry()..stale = false,
    };

    markSwitchedSessionPreviewsStale(
      previews,
      fromChannelId: 'a',
      toChannelId: 'b',
    );

    expect(previews['a']!.stale, isTrue);
    expect(previews['b']!.stale, isTrue);
    expect(previews['c']!.stale, isFalse);
  });

  test('same channel does not mark any row stale', () {
    final previews = {
      'a': SessionPreviewEntry()..stale = false,
    };

    markSwitchedSessionPreviewsStale(
      previews,
      fromChannelId: 'a',
      toChannelId: 'a',
    );

    expect(previews['a']!.stale, isFalse);
  });
}
