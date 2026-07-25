import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/sync/sync_frame.dart';

void main() {
  group('SyncFrame.tryParse', () {
    test('parses a well-formed frame and strips envelope keys', () {
      final frame = SyncFrame.tryParse(<String, dynamic>{
        'ns': 'sync',
        'op': 'pull',
        'epoch': 3,
        'v': 1,
        'cursor': 10234,
        'limit': 500,
      });

      expect(frame, isNotNull);
      expect(frame!.op, SyncOp.pull);
      expect(frame.epoch, 3);
      expect(frame.v, 1);
      expect(frame.payload, <String, dynamic>{'cursor': 10234, 'limit': 500});
    });

    test('returns null for non-sync namespaces', () {
      expect(SyncFrame.tryParse(<String, dynamic>{'ns': 'chat', 'op': 'x'}),
          isNull);
      expect(SyncFrame.tryParse(<String, dynamic>{'type': 'hello'}), isNull);
    });

    test('throws on missing op / epoch', () {
      expect(
        () => SyncFrame.tryParse(<String, dynamic>{'ns': 'sync', 'epoch': 1}),
        throwsFormatException,
      );
      expect(
        () => SyncFrame.tryParse(
            <String, dynamic>{'ns': 'sync', 'op': 'pull'}),
        throwsFormatException,
      );
    });

    test('missing v defaults to 0 and is unsupported', () {
      final frame = SyncFrame.tryParse(
          <String, dynamic>{'ns': 'sync', 'op': 'pull', 'epoch': 1});
      expect(frame!.versionSupported, isFalse);
    });
  });

  group('SyncFrame.toJson', () {
    test('round-trips envelope and payload', () {
      final original = SyncFrame(
        op: SyncOp.changes,
        epoch: 1,
        payload: <String, dynamic>{
          'from': 1,
          'to': 2,
          'has_more': false,
          'tables': <String, dynamic>{},
        },
      );
      final wire = original.toJson();
      // peer 层按扁平 type 路由控制帧，spec §1 传输映射要求恒为 "sync"。
      expect(wire['type'], kSyncControlType);
      final parsed = SyncFrame.tryParse(wire)!;
      expect(parsed.op, original.op);
      expect(parsed.epoch, original.epoch);
      expect(parsed.v, kSyncProtocolVersion);
      expect(parsed.payload, original.payload);
      expect(parsed.payload.containsKey('type'), isFalse);
    });
  });

  test('syncErrorFrame builds spec §1 error payloads', () {
    final err = syncErrorFrame(
      epoch: 2,
      refOp: SyncOp.pull,
      code: SyncErrorCode.cursorTooOld,
      message: 'resync required',
    );
    final json = err.toJson();
    expect(json['ns'], 'sync');
    expect(json['op'], 'error');
    expect(json['ref_op'], 'pull');
    expect(json['code'], 'cursor_too_old');
    expect(json['message'], 'resync required');
  });
}
