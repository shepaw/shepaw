import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
import 'package:shepaw/identity/utils/sync_lww.dart';

void main() {
  group('AccountIdentityService.primaryWinnerDeviceId', () {
    test('picks lexicographically smaller device id', () {
      expect(
        AccountIdentityService.primaryWinnerDeviceId('device-a', 'device-z'),
        'device-a',
      );
      expect(
        AccountIdentityService.primaryWinnerDeviceId('zzz', 'aaa'),
        'aaa',
      );
    });

    test('returns either when equal', () {
      expect(
        AccountIdentityService.primaryWinnerDeviceId('same', 'same'),
        'same',
      );
    });
  });

  group('SyncLww', () {
    test('isIncomingStale rejects older wall time', () {
      expect(
        SyncLww.isIncomingStale(incomingWallTimeMs: 100, existingWallTimeMs: 200),
        isTrue,
      );
      expect(
        SyncLww.isIncomingStale(incomingWallTimeMs: 200, existingWallTimeMs: 200),
        isFalse,
      );
      expect(
        SyncLww.isIncomingStale(incomingWallTimeMs: 300, existingWallTimeMs: 200),
        isFalse,
      );
    });

    test('isoRowTimeMs parses updated_at', () {
      final ms = SyncLww.isoRowTimeMs(
        {'updated_at': '2024-01-02T03:04:05.000Z'},
        ['updated_at', 'created_at'],
      );
      expect(ms, DateTime.parse('2024-01-02T03:04:05.000Z').millisecondsSinceEpoch);
    });

    test('intRowTimeMs reads first int key', () {
      expect(
        SyncLww.intRowTimeMs({'created_at': 10, 'updated_at': 20}, ['updated_at', 'created_at']),
        20,
      );
    });
  });
}
