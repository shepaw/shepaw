import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/channel_tunnel_service.dart';

/// 隧道活性判定。真实 socket 的半开行为没法在单测里复现，这里只钉住阈值：
/// relay 每 20s 一个 ping，120s 静默 = 连续 6 次没收到。
void main() {
  const timeout = Duration(seconds: 120);
  final now = DateTime(2026, 10, 26, 12);

  test('刚连上还没收到任何帧时不算超时', () {
    expect(tunnelInboundExpired(null, now, timeout), isFalse);
  });

  test('窗口内收到过帧就不算超时', () {
    expect(
      tunnelInboundExpired(
        now.subtract(const Duration(seconds: 119)),
        now,
        timeout,
      ),
      isFalse,
    );
  });

  test('静默达到或超过窗口就算超时', () {
    expect(
      tunnelInboundExpired(
        now.subtract(const Duration(seconds: 120)),
        now,
        timeout,
      ),
      isTrue,
    );
    expect(
      tunnelInboundExpired(
        now.subtract(const Duration(minutes: 5)),
        now,
        timeout,
      ),
      isTrue,
    );
  });
}
