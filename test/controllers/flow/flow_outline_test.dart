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

    test('加子步骤：if 的两个分支分别给 branch', () {
      final rows = buildFlowOutline(_ifTree());
      final pick = rows.firstWhere((r) => r.node.id == 'pick');
      expect(
        FlowOutlineOps.insertChild(pick.node, const {}, branch: 'then'),
        {
          'op': 'insert',
          'parent_id': 'pick',
          'index': 0,
          'branch': 'then',
          'step': const {},
        },
      );
      expect(
        FlowOutlineOps.insertChild(pick.node, const {}, branch: 'else'),
        {
          'op': 'insert',
          'parent_id': 'pick',
          'index': 0,
          'branch': 'else',
          'step': const {},
        },
      );
    });

    test('改类型只发一个 retype', () {
      final rows = buildFlowOutline(_ifTree());
      final t1 = rows.firstWhere((r) => r.node.id == 't1');
      expect(
        FlowOutlineOps.retype(t1, 'gate'),
        {'op': 'retype', 'node_id': 't1', 'kind': 'gate'},
      );
    });

    test('缩进：移进上一个兄弟 vs 和它一起包起来', () {
      final rows = buildFlowOutline([
        FlowNode(
          key: 'a',
          id: 'a',
          kind: 'seq',
          children: [_task('x')],
        ),
        _task('b'),
      ]);
      final b = rows.firstWhere((r) => r.node.id == 'b');
      // 上一个兄弟是容器：直接改父节点，不新建容器、不改执行语义。
      expect(FlowOutlineOps.moveIntoPrevious(b), {
        'op': 'move',
        'node_id': 'b',
        'parent_id': 'a',
      });
      // 包起来是显式选择，且要写清是哪一种（并行 / 循环 会改语义）。
      expect(
        FlowOutlineOps.wrapWithPrevious(b, 'par', 'wrap-1'),
        [
          {
            'op': 'wrap',
            'node_id': 'a',
            'kind': 'par',
            'wrapper_id': 'wrap-1',
          },
          {'op': 'move', 'node_id': 'b', 'parent_id': 'wrap-1'},
        ],
      );
    });

    test('跨分支移动要显式带 branch，不按拼接下标', () {
      final rows = buildFlowOutline(_ifTree());
      final e1 = rows.firstWhere((r) => r.node.id == 'e1');
      expect(FlowOutlineOps.moveToBranch(e1, 'then'), {
        'op': 'move',
        'node_id': 'e1',
        'parent_id': 'pick',
        'branch': 'then',
      });
    });

    test('取消缩进：挪到父节点后面那一层', () {
      final rows = buildFlowOutline([
        FlowNode(
          key: 'build',
          id: 'build',
          kind: 'seq',
          children: [_task('x'), _task('b')],
        ),
      ]);
      final b = rows.firstWhere((r) => r.node.id == 'b');
      expect(b.canOutdent, isTrue);
      // 插在父节点之后（index + 1），顺序看起来没变。
      expect(FlowOutlineOps.outdent(b), {
        'op': 'move',
        'node_id': 'b',
        'parent_id': '',
        'index': 1,
      });
      // 根层的行没有父行，取消缩进不可用。
      final build = rows.firstWhere((r) => r.node.id == 'build');
      expect(build.canOutdent, isFalse);
    });

    test('前一个兄弟在同一支里找', () {
      final rows = buildFlowOutline(_ifTree());
      final byId = {for (final r in rows) r.node.id: r};
      // e2 的前一个是 e1，不能是 t2（跨支）。
      expect(byId['e2']!.previousSibling?.id, 'e1');
      expect(byId['e1']!.previousSibling, isNull);
      expect(byId['t2']!.previousSibling?.id, 't1');
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
