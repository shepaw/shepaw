import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_diagnostics.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/hub_flow.dart';

void main() {
  final tree = [
    FlowNode(
      key: 'l',
      id: 'l',
      kind: 'loop',
      children: [
        FlowNode(key: 'l#0/t', id: 't', kind: 'task'),
      ],
    ),
  ];

  test('loop 里的节点也能定位到：取最后一段按 id 匹配', () {
    // 诊断的 at 是 `l/t`，而树里的 key 是 `l#0/t` —— 直接比会找不到。
    expect(
      resolveDiagnostic(FlowDiagnostic(at: 'l/t', severity: 'error', message: 'x'), tree),
      isA<NodeTarget>(),
    );
    final target =
        resolveDiagnostic(FlowDiagnostic(at: 'l/t', severity: 'error', message: 'x'), tree);
    expect((target as NodeTarget).nodeId, 't');
  });

  test('头部字段认成 HeaderTarget', () {
    for (final at in ['inputs.goal', 'limits.timeout', 'description']) {
      expect(
        resolveDiagnostic(FlowDiagnostic(at: at, severity: 'error', message: 'x'), tree),
        isA<HeaderTarget>(),
        reason: at,
      );
    }
  });

  test('空的、或找不到对应节点的，都是 GlobalTarget', () {
    expect(
      resolveDiagnostic(FlowDiagnostic(at: '', severity: 'error', message: 'x'), tree),
      isA<GlobalTarget>(),
    );
    expect(
      resolveDiagnostic(FlowDiagnostic(at: 'nope', severity: 'error', message: 'x'), tree),
      isA<GlobalTarget>(),
    );
  });
}
