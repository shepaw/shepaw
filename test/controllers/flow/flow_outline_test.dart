import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_outline.dart';
import 'package:shepaw/peer/models/flow_models.dart';

/// `if` 的两支在 `children` 里是拼在一起的，顺序是 then 全部在前、else 在后。
FlowNode _task(String id, {String? branch}) => FlowNode(
      key: id,
      id: id,
      kind: 'task',
      branch: branch,
    );

List<FlowNode> _ifTree() => [
      FlowNode(
        key: 'pick',
        id: 'pick',
        kind: 'if',
        children: [
          _task('t1', branch: 'then'),
          _task('t2', branch: 'then'),
          _task('e1', branch: 'else'),
          _task('e2', branch: 'else'),
        ],
      ),
    ];

void main() {
  group('buildFlowOutline', () {
    test('if 内的下标按分支算，不是拼起来的下标', () {
      final rows = buildFlowOutline(_ifTree());
      final byId = {for (final r in rows) r.node.id: r};
      expect(byId['pick']!.index, 0);
      expect(byId['pick']!.branch, isNull);
      // then 支：0、1
      expect(byId['t1']!.index, 0);
      expect(byId['t2']!.index, 1);
      // else 支重新从 0 开始 —— 否则 e1 会被当成下标 2，一上移就跳进 then。
      expect(byId['e1']!.index, 0);
      expect(byId['e1']!.branch, 'else');
      expect(byId['e2']!.index, 1);
      expect(byId['e2']!.branch, 'else');
    });

    test('分支边界上的上移 / 下移不可用', () {
      final rows = buildFlowOutline(_ifTree());
      final byId = {for (final r in rows) r.node.id: r};
      // e1 是 else 支的第一个，不能再往上（上去就跨到 then 了）。
      expect(byId['e1']!.canMoveUp, isFalse);
      expect(byId['e1']!.canMoveDown, isTrue);
      expect(byId['e2']!.canMoveUp, isTrue);
      expect(byId['e2']!.canMoveDown, isFalse);
      // then 支同理。
      expect(byId['t1']!.canMoveUp, isFalse);
      expect(byId['t2']!.canMoveDown, isFalse);
    });

    test('没有 branch 标记时按 then 处理', () {
      final rows = buildFlowOutline([
        FlowNode(
          key: 'pick',
          id: 'pick',
          kind: 'if',
          children: [_task('a'), _task('b')],
        ),
      ]);
      final byId = {for (final r in rows) r.node.id: r};
      expect(byId['a']!.branch, 'then');
      expect(byId['b']!.branch, 'then');
    });
  });

  group('FlowOutlineOps', () {
    test('else 内上移带 branch 和分支内下标', () {
      final rows = buildFlowOutline(_ifTree());
      final e2 = rows.firstWhere((r) => r.node.id == 'e2');
      expect(FlowOutlineOps.moveUp(e2), {
        'op': 'move',
        'node_id': 'e2',
        'parent_id': 'pick',
        // 分支内下标 1 → 0，且必须带 branch，否则落进 then。
        'index': 0,
        'branch': 'else',
      });
    });

    test('else 内加一步落在同一支', () {
      final rows = buildFlowOutline(_ifTree());
      final e1 = rows.firstWhere((r) => r.node.id == 'e1');
      expect(FlowOutlineOps.insertAfter(e1, const {}), {
        'op': 'insert',
        'parent_id': 'pick',
        'index': 1,
        'branch': 'else',
        'step': const {},
      });
    });

    test('普通容器不带 branch', () {
      final rows = buildFlowOutline([
        FlowNode(
          key: 'build',
          id: 'build',
          kind: 'seq',
          children: [_task('a'), _task('b')],
        ),
      ]);
      final b = rows.firstWhere((r) => r.node.id == 'b');
      expect(FlowOutlineOps.moveUp(b), {
        'op': 'move',
        'node_id': 'b',
        'parent_id': 'build',
        'index': 0,
      });
    });
  });

  test('flowLocate 也认分支', () {
    final hit = flowLocate(_ifTree(), 'e2')!;
    expect(hit.parent?.id, 'pick');
    expect(hit.branch, 'else');
    // 拼起来的下标是 3，分支内是 1。
    expect(hit.index, 1);
  });
}
