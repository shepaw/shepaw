import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/screens/jade_slip_screen.dart';

JadeSlip _slip(String id, JadeSlipStatus status) {
  return JadeSlip(
    id: id,
    title: id,
    status: status,
    deviceId: 'dev',
    createdAt: 1,
    updatedAt: 1,
  );
}

void main() {
  test('status-changed slip stays at its previous index', () {
    final filtered = [_slip('a', JadeSlipStatus.done)];
    final kept = _slip('b', JadeSlipStatus.inProgress);
    final next = insertRetainedJadeSlip(
      items: filtered,
      retained: kept,
      anchorIndex: 0,
    );
    expect(next.map((s) => s.id), ['b', 'a']);
  });

  test('slip already in the filter is not duplicated', () {
    final kept = _slip('a', JadeSlipStatus.done);
    final next = insertRetainedJadeSlip(
      items: [kept],
      retained: kept,
      anchorIndex: 0,
    );
    expect(next, hasLength(1));
  });

  test('archived slip is not put back', () {
    final next = insertRetainedJadeSlip(
      items: [_slip('a', JadeSlipStatus.open)],
      retained: _slip('b', JadeSlipStatus.archived),
      anchorIndex: 0,
    );
    expect(next.map((s) => s.id), ['a']);
  });

  test('query matches title, body, and checklist text', () {
    final slip = const JadeSlip(
      id: 'a',
      title: '买菜',
      body: '周末',
      items: const [],
      deviceId: 'dev',
      createdAt: 1,
      updatedAt: 1,
    );
    expect(jadeSlipMatchesQuery(slip, '买'), isTrue);
    expect(jadeSlipMatchesQuery(slip, '周末'), isTrue);
    expect(jadeSlipMatchesQuery(slip, '没有'), isFalse);
    expect(jadeSlipMatchesQuery(slip, '  '), isTrue);
  });
}
