import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/interaction_card_close.dart';
import 'package:shepaw/services/serial_task_queue.dart';

/// 模拟 messages 表里的一行：metadata 以 JSON 字符串落库，读写都有异步边界。
class _CardRow {
  _CardRow(Map<String, dynamic> metadata) : _raw = jsonEncode(metadata);

  String _raw;

  Future<Map<String, dynamic>> read() async =>
      Map<String, dynamic>.from(jsonDecode(_raw) as Map);

  Future<void> write(Map<String, dynamic> metadata) async {
    _raw = jsonEncode(metadata);
  }

  Map<String, dynamic> get metadata =>
      Map<String, dynamic>.from(jsonDecode(_raw) as Map);
}

/// 和 [_CardRow] 上真实写库路径同形：读、改、写，但没排队。
Future<void> _naiveWrite(
  _CardRow row,
  Map<String, dynamic>? Function(Map<String, dynamic> metadata) close,
) async {
  final snapshot = await row.read();
  final next = close(snapshot);
  if (next == null) return;
  await row.write(next);
}

/// 队列版：真正的实现在锁内重读最新行，再改、再写。
Future<void> _serializedWrite(
  SerialTaskQueue<String> queue,
  _CardRow row,
  Map<String, dynamic>? Function(Map<String, dynamic> metadata) close,
) {
  return queue.run('m1', () async {
    final fresh = await row.read();
    final next = close(fresh);
    if (next == null) return;
    await row.write(next);
  });
}

Map<String, dynamic> _openForm() => {
      'form': {
        'form_id': 'approval-1',
        'peer_form': {'approval_id': 'approval-1'},
        'title': 'Pick one',
      },
    };

Map<String, dynamic> _formOf(_CardRow row) =>
    Map<String, dynamic>.from(row.metadata['form'] as Map);

void main() {
  group('deferred 与 turn_ended 的 metadata 读改写', () {
    test('不排队时，后到的 turn_ended 会冲掉刚写的 deferred', () async {
      final row = _CardRow(_openForm());

      // 两次写都在对方落库前读到同一份旧快照。
      await Future.wait([
        _naiveWrite(
          row,
          (metadata) => metadataMarkingFormDeferred(
            metadata,
            interactionId: 'approval-1',
          ),
        ),
        _naiveWrite(
          row,
          (metadata) => metadataClosingOpenCards(
            metadata,
            reason: 'turn_ended',
          ),
        ),
      ]);

      final form = _formOf(row);
      expect(form['deferred'], isNull);
      expect(form['closed'], 'turn_ended');
    });

    test('排队后 deferred 先写、turn_ended 后到：卡片保持可答', () async {
      final queue = SerialTaskQueue<String>();
      final row = _CardRow(_openForm());

      await Future.wait([
        _serializedWrite(
          queue,
          row,
          (metadata) => metadataMarkingFormDeferred(
            metadata,
            interactionId: 'approval-1',
          ),
        ),
        _serializedWrite(
          queue,
          row,
          (metadata) => metadataClosingOpenCards(
            metadata,
            reason: 'turn_ended',
          ),
        ),
      ]);

      final form = _formOf(row);
      expect(form['deferred'], isTrue);
      expect(form['closed'], isNull);
    });

    test('排队后 turn_ended 先写、deferred 后到：清掉 closed 并保持可答', () async {
      final queue = SerialTaskQueue<String>();
      final row = _CardRow(_openForm());

      await Future.wait([
        _serializedWrite(
          queue,
          row,
          (metadata) => metadataClosingOpenCards(
            metadata,
            reason: 'turn_ended',
          ),
        ),
        _serializedWrite(
          queue,
          row,
          (metadata) => metadataMarkingFormDeferred(
            metadata,
            interactionId: 'approval-1',
          ),
        ),
      ]);

      final form = _formOf(row);
      expect(form['deferred'], isTrue);
      expect(form['closed'], isNull);
    });

    test('写失败不会堵住同一行的下一次写', () async {
      final queue = SerialTaskQueue<String>();
      var ran = false;

      final failed = queue.run('m1', () async => throw StateError('boom'));
      final next = queue.run('m1', () async {
        ran = true;
      });

      await expectLater(failed, throwsStateError);
      await next;
      expect(ran, isTrue);
    });

    test('不同 key 不互相阻塞', () async {
      final queue = SerialTaskQueue<String>();
      final gate = Completer<void>();

      final blocked = queue.run('a', () => gate.future);
      var ranB = false;
      await queue.run('b', () async {
        ranB = true;
      });

      expect(ranB, isTrue);
      gate.complete();
      await blocked;
    });
  });
}
