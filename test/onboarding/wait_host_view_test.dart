import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/wait_host_view.dart';

WaitHostController build(
  FakeAsync async, {
  required List<bool> answers,
  WaitHostController Function({
    required String hostPeerId,
    required Future<bool> Function(String hostPeerId) probe,
    void Function(Object error)? onError,
  })? factory,
}) {
  var calls = 0;
  return WaitHostController(
    hostPeerId: 'peer-1',
    interval: const Duration(seconds: 3),
    timeout: const Duration(minutes: 10),
    probe: (_) async {
      final answer = calls < answers.length ? answers[calls] : false;
      calls++;
      return answer;
    },
  );
}

void main() {
  test('主机还没设好时一直轮询', () {
    fakeAsync((async) {
      final controller = build(async, answers: const [false]);
      controller.start();
      async.elapse(const Duration(seconds: 1));
      expect(controller.checks, 1);
      async.elapse(const Duration(seconds: 6));
      expect(controller.checks, greaterThan(2));
      expect(controller.ready, isFalse);
      controller.dispose();
    });
  });

  test('设好之后自动停，只回调一次', () {
    fakeAsync((async) {
      final controller = build(async, answers: const [false, true]);
      controller.start();
      async.elapse(const Duration(seconds: 3));
      expect(controller.checks, 2);
      expect(controller.ready, isTrue);
      final before = controller.checks;
      async.elapse(const Duration(seconds: 30));
      expect(controller.checks, before);
      controller.dispose();
    });
  });

  test('进后台暂停，回前台立刻查一次', () {
    fakeAsync((async) {
      final controller = build(async, answers: const [false]);
      controller.start();
      async.elapse(const Duration(seconds: 1));
      final afterStart = controller.checks;
      controller.pause();
      async.elapse(const Duration(seconds: 30));
      expect(controller.checks, afterStart);
      controller.resume();
      async.elapse(const Duration(seconds: 1));
      expect(controller.checks, afterStart + 1);
      controller.dispose();
    });
  });

  test('10 分钟没等到就放弃，不再问', () {
    fakeAsync((async) {
      final controller = build(async, answers: const [false]);
      controller.start();
      async.elapse(const Duration(minutes: 10));
      expect(controller.gaveUp, isTrue);
      final before = controller.checks;
      async.elapse(const Duration(minutes: 5));
      expect(controller.checks, before);
      controller.dispose();
    });
  });

  test('问主机失败不会把等待打断', () {
    fakeAsync((async) {
      final errors = <Object>[];
      final controller = WaitHostController(
        hostPeerId: 'peer-1',
        interval: const Duration(seconds: 3),
        timeout: const Duration(minutes: 10),
        probe: (_) async => throw StateError('连不上'),
        onError: errors.add,
      );
      controller.start();
      async.elapse(const Duration(seconds: 1));
      expect(errors, isNotEmpty);
      expect(controller.ready, isFalse);
      expect(controller.gaveUp, isFalse);
      controller.dispose();
    });
  });
}
