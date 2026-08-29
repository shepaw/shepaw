import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Mirror of ChatService's per-channel trailing-debounce notify logic,
/// extracted so the merge behavior can be verified without the service.
class DebouncedNotifier {
  final Duration delay;
  final void Function(String channelId) emit;
  final Map<String, Timer> _timers = {};

  DebouncedNotifier({required this.delay, required this.emit});

  void notify(String channelId) {
    _timers[channelId]?.cancel();
    _timers[channelId] = Timer(delay, () {
      _timers.remove(channelId);
      emit(channelId);
    });
  }

  void notifyNow(String channelId) {
    _timers[channelId]?.cancel();
    _timers.remove(channelId);
    emit(channelId);
  }

  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}

/// Mirror of the controller-side single-flight guard for group reconcile.
class SingleFlight {
  final Future<void> Function() task;
  bool _running = false;
  bool _queued = false;
  int started = 0;

  SingleFlight({required this.task});

  Future<void> schedule() async {
    if (_running) {
      _queued = true;
      return;
    }
    _running = true;
    try {
      started++;
      await task();
    } finally {
      _running = false;
      if (_queued) {
        _queued = false;
        await schedule();
      }
    }
  }
}

void main() {
  group('DebouncedNotifier (chat_service _notifyChannelUpdate 语义)', () {
    test('burst of notifies on one channel collapses to one emit', () async {
      final emitted = <String>[];
      final notifier = DebouncedNotifier(
        delay: const Duration(milliseconds: 20),
        emit: emitted.add,
      );
      for (var i = 0; i < 10; i++) {
        notifier.notify('ch1');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emitted, ['ch1']);
    });

    test('different channels debounce independently', () async {
      final emitted = <String>[];
      final notifier = DebouncedNotifier(
        delay: const Duration(milliseconds: 20),
        emit: emitted.add,
      );
      notifier.notify('ch1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      notifier.notify('ch2');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(emitted, ['ch1', 'ch2']);
    });

    test('notifyNow bypasses the debounce and cancels the pending timer',
        () async {
      final emitted = <String>[];
      final notifier = DebouncedNotifier(
        delay: const Duration(milliseconds: 50),
        emit: emitted.add,
      );
      notifier.notify('ch1');
      notifier.notifyNow('ch1');
      expect(emitted, ['ch1']);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Debounced timer was cancelled — no double emit.
      expect(emitted, ['ch1']);
    });

    test('cancelAll drops pending emits', () async {
      final emitted = <String>[];
      final notifier = DebouncedNotifier(
        delay: const Duration(milliseconds: 20),
        emit: emitted.add,
      );
      notifier.notify('ch1');
      notifier.cancelAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emitted, isEmpty);
    });
  });

  group('SingleFlight (controller group reconcile 语义)', () {
    test('overlapping schedules collapse: one run + one queued tail run',
        () async {
      var active = 0;
      var maxConcurrent = 0;
      final gate = Completer<void>();
      final flight = SingleFlight(task: () async {
        active++;
        maxConcurrent = active > maxConcurrent ? active : maxConcurrent;
        await gate.future;
        active--;
      });

      // First call runs; the next 5 arrive mid-run and must only queue once.
      final first = flight.schedule();
      await Future<void>.delayed(Duration.zero);
      final others = <Future<void>>[
        for (var i = 0; i < 5; i++) flight.schedule(),
      ];
      expect(flight.started, 1);

      gate.complete();
      await first;
      await Future.wait(others);

      expect(maxConcurrent, 1, reason: 'reconcile must never run concurrently');
      expect(flight.started, 2,
          reason: 'exactly one queued tail run should converge final state');
    });

    test('no overlap → every schedule runs', () async {
      final flight = SingleFlight(task: () async {});
      await flight.schedule();
      await flight.schedule();
      await flight.schedule();
      expect(flight.started, 3);
    });

    test('task error still resets the guard and drains the queue', () async {
      var calls = 0;
      final flight = SingleFlight(task: () async {
        calls++;
        if (calls == 1) throw StateError('boom');
      });
      await expectLater(flight.schedule(), throwsStateError);
      await flight.schedule();
      expect(calls, 2);
    });
  });
}
