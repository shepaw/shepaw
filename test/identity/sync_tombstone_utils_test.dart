import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/sync_tombstone_utils.dart';

void main() {
  group('SyncTombstoneUtils', () {
    const now = 1000000000000;
    const day = 86400000;

    test('uses minimum 30 day retention when all devices online', () {
      final cutoff = SyncTombstoneUtils.pruneCutoffWallTimeMs(
        nowMs: now,
        deviceLastSeenMs: [now - day, now - 2 * day],
      );
      expect(cutoff, now - 30 * day);
    });

    test('extends retention for long offline device', () {
      final cutoff = SyncTombstoneUtils.pruneCutoffWallTimeMs(
        nowMs: now,
        deviceLastSeenMs: [now - day, now - 60 * day],
      );
      expect(cutoff, now - 60 * day);
    });

    test('caps retention at 90 days', () {
      final cutoff = SyncTombstoneUtils.pruneCutoffWallTimeMs(
        nowMs: now,
        deviceLastSeenMs: [now - 120 * day],
      );
      expect(cutoff, now - 90 * day);
    });

    test('old min-lastSeen logic would prune too aggressively', () {
      const offlineDeviceLastSeen = now - 60 * day;
      final oldCutoff = now - 30 * day;
      if (offlineDeviceLastSeen < oldCutoff) {
        // legacy bug: cutoff pulled to lastSeen, deleting tombstones between 30-60d offline
      }
      final newCutoff = SyncTombstoneUtils.pruneCutoffWallTimeMs(
        nowMs: now,
        deviceLastSeenMs: [now - day, offlineDeviceLastSeen],
      );
      expect(newCutoff, lessThan(oldCutoff));
      expect(newCutoff, offlineDeviceLastSeen);
    });
  });
}
