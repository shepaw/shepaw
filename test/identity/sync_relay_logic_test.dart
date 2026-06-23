import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/sync_relay_logic.dart';

void main() {
  group('SyncRelayLogic.isEventStaleAgainstState', () {
    test('relay event older than entity state is superseded', () {
      expect(
        SyncRelayLogic.isEventStaleAgainstState(
          eventWallTimeMs: 100,
          eventId: 'msg:old:del:100',
          originDeviceId: 'app-1',
          stateWallTimeMs: 200,
          stateEventId: 'msg:old',
          stateOriginDeviceId: 'primary-1',
          rowWallTimeMs: 200,
        ),
        isTrue,
      );
    });

    test('relay event newer than entity state is not superseded', () {
      expect(
        SyncRelayLogic.isEventStaleAgainstState(
          eventWallTimeMs: 300,
          eventId: 'msg:new',
          originDeviceId: 'app-1',
          stateWallTimeMs: 200,
          stateEventId: 'msg:old',
          stateOriginDeviceId: 'primary-1',
          rowWallTimeMs: 200,
        ),
        isFalse,
      );
    });

    test('no local state yet is not superseded', () {
      expect(
        SyncRelayLogic.isEventStaleAgainstState(
          eventWallTimeMs: 100,
          eventId: 'msg:a',
          originDeviceId: 'app-1',
          stateWallTimeMs: 0,
          stateEventId: '',
          stateOriginDeviceId: '',
          rowWallTimeMs: 0,
        ),
        isFalse,
      );
    });
  });
}
