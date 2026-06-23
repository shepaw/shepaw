import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/sync_push_backoff.dart';

void main() {
  group('SyncPushBackoff', () {
    test('first retry waits base delay', () {
      expect(SyncPushBackoff.delayMsForRetryCount(1), 5000);
    });

    test('exponential growth caps at max delay', () {
      expect(SyncPushBackoff.delayMsForRetryCount(2), 10000);
      expect(SyncPushBackoff.delayMsForRetryCount(3), 20000);
      expect(SyncPushBackoff.delayMsForRetryCount(10), SyncPushBackoff.maxDelayMs);
    });

    test('nextRetryAtMs adds delay to now', () {
      const now = 1000000;
      expect(
        SyncPushBackoff.nextRetryAtMs(2, now),
        now + 10000,
      );
    });
  });
}
