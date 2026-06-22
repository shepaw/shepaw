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

  group('resolvePrimaryWinnerAmong (logic)', () {
    String pickWinner(List<String> ids, String? elected) {
      if (ids.isEmpty) return '';
      if (ids.length == 1) return ids.first;
      if (elected != null && elected.isNotEmpty && ids.contains(elected)) {
        return elected;
      }
      return ids.reduce(AccountIdentityService.primaryWinnerDeviceId);
    }

    test('user elected primary wins over lex', () {
      expect(
        pickWinner(['device-z', 'device-a'], 'device-z'),
        'device-z',
      );
    });

    test('falls back to lex when no user election', () {
      expect(
        pickWinner(['device-z', 'device-a'], null),
        'device-a',
      );
    });

    test('ignores elected id not in candidates', () {
      expect(
        pickWinner(['device-z', 'device-a'], 'device-other'),
        'device-a',
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

    test('isIncomingStale tie-breaks equal wall time by event id', () {
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 100,
          existingWallTimeMs: 100,
          incomingEventId: 'msg:a',
          existingEventId: 'msg:b',
        ),
        isTrue,
      );
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 100,
          existingWallTimeMs: 100,
          incomingEventId: 'msg:c',
          existingEventId: 'msg:b',
        ),
        isFalse,
      );
    });

    test('isIncomingStale tie-breaks equal wall time by origin device id', () {
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 100,
          existingWallTimeMs: 100,
          incomingEventId: 'msg:same',
          existingEventId: 'msg:same',
          incomingOriginDeviceId: 'device-a',
          existingOriginDeviceId: 'device-z',
        ),
        isTrue,
      );
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 100,
          existingWallTimeMs: 100,
          incomingEventId: 'msg:same',
          existingEventId: 'msg:same',
          incomingOriginDeviceId: 'device-z',
          existingOriginDeviceId: 'device-a',
        ),
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
