import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_streaming_text.dart';

void main() {
  group('ChatStreamingSession.onClear', () {
    test('fires when an active session is cleared', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.begin('streaming_1');
      expect(s.isActive, isTrue);
      s.clear();

      expect(calls, 1);
      expect(s.isActive, isFalse);
      expect(s.content, '');
    });

    test('does not fire when clearing an already-inactive session', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.clear(); // 从未 begin
      expect(calls, 0);

      s.begin('streaming_1');
      s.clear();
      s.clear(); // 重复 clear 不重复触发
      expect(calls, 1);
    });

    test('begin after clear starts a fresh cycle that fires again', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.begin('streaming_1');
      s.append('hello');
      s.clear();
      s.begin('streaming_2');
      expect(s.content, '');
      s.clear();

      expect(calls, 2);
    });
  });
}
