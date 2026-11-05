import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/warm_ready_registry.dart';

void main() {
  test('warm readiness is tracked per agent and session', () {
    final registry = WarmReadyRegistry.instance;
    registry.clear('a1', 's1');
    registry.clear('a1', 's2');

    expect(registry.isReady('a1', 's1'), isFalse);
    registry.record('a1', 's1', true);
    expect(registry.isReady('a1', 's1'), isTrue);
    expect(registry.isReady('a1', 's2'), isFalse);

    registry.record('a1', 's2', false);
    expect(registry.isReady('a1', 's2'), isFalse);
    expect(
      registry.snapshot.containsKey(WarmReadyRegistry.key('a1', 's2')),
      isTrue,
    );

    registry.clear('a1', 's1');
    expect(registry.isReady('a1', 's1'), isFalse);
  });
}
