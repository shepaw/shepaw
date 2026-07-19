import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  group('clampPeerMessageTimestamp', () {
    test('keeps remote timestamp when no local messages exist', () {
      expect(clampPeerMessageTimestamp(1000, null), 1000);
    });

    test('keeps remote timestamp when it is newer than local latest', () {
      // 对端时钟偏快不影响因果顺序，保留原时间戳
      expect(clampPeerMessageTimestamp(5000, 1000), 5000);
    });

    test('clamps to latest+1 when remote clock is behind', () {
      // 典型场景：对端时钟偏慢几秒，快速一问一答时回复的 timestamp 早于
      // 本地刚发出的消息——不钳制则重载后排序与到达顺序相反（上下浮动）
      expect(clampPeerMessageTimestamp(900, 1000), 1001);
    });

    test('clamps when remote timestamp equals local latest', () {
      expect(clampPeerMessageTimestamp(1000, 1000), 1001);
    });

    test('sequential clamping preserves arrival order', () {
      // 连续两条迟到消息：分别压到最新+1、再+1，相对顺序保持
      var latest = 1000;
      final a = clampPeerMessageTimestamp(900, latest);
      latest = a;
      final b = clampPeerMessageTimestamp(800, latest);
      expect(a, 1001);
      expect(b, 1002);
      expect(b > a, isTrue);
    });
  });
}
