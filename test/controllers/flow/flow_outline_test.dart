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

  group('resolveDrop', () {
    List<FlowNode> chain() => [
          FlowNode(key: 'a', id: 'a', kind: 'task'),
          FlowNode(key: 'b', id: 'b', kind: 'task'),
          FlowNode(key: 'c', id: 'c', kind: 'task'),
        ];

    test('同父上移：before 用 over.index，不减 1', () {
      final rows = buildFlowOutline(chain()); // a@0 b@1 c@2
      final t = resolveDrop(rows, 'c', 'a', DropZone.before)!;
      expect(t.dragId, 'c');
      expect(t.parentId, '');
      expect(t.index, 0);
      expect(t.branch, isNull);
    });

    test('同父下移：after 的 index − 1（主机先摘后插）', () {
      final rows = buildFlowOutline(chain());
      // 把 a 拖到 c 之后：base = 2 + 1 = 3，摘掉 a 后 → 2。
      final t = resolveDrop(rows, 'a', 'c', DropZone.after)!;
      expect(t.parentId, '');
      expect(t.index, 2);
    });

    test('同父下移：before 也减 1（贴着后一个兄弟放是 no-op）', () {
      final rows = buildFlowOutline(chain());
      final t = resolveDrop(rows, 'a', 'b', DropZone.before)!;
      expect(t.index, 0);
    });

    test('跨父：不减 1，parent 用 over 的父', () {
      final rows = buildFlowOutline([
        FlowNode(key: 'x', id: 'x', kind: 'seq', children: [
          FlowNode(key: 'm', id: 'm', kind: 'task'),
        ]),
        FlowNode(key: 'y', id: 'y', kind: 'seq', children: [
          FlowNode(key: 'n', id: 'n', kind: 'task'),
        ]),
      ]);
      final t = resolveDrop(rows, 'm', 'n', DropZone.before)!;
      expect(t.parentId, 'y');
      expect(t.index, 0);
    });

    test('if：把 else 的节点拖到 then 的某行之前，branch 跟着目标', () {
      final rows = buildFlowOutline(_ifTree());
      final t = resolveDrop(rows, 'e1', 't2', DropZone.before)!;
      expect(t.parentId, 'pick');
      expect(t.branch, 'then');
      // 跨分支没有「摘掉自己后目标前移」的问题，不减 1。
      expect(t.index, 1);
    });

    test('into if：必须给 branch，追加（index 为 null）', () {
      final rows = buildFlowOutline([
        ..._ifTree(),
        FlowNode(key: 'z', id: 'z', kind: 'task'),
      ]);
      expect(resolveDrop(rows, 'z', 'pick', DropZone.into), isNull);
      final then =
          resolveDrop(rows, 'z', 'pick', DropZone.into, branch: 'then')!;
      expect(then.parentId, 'pick');
      expect(then.index, isNull);
      expect(then.branch, 'then');
      expect(
          resolveDrop(rows, 'z', 'pick', DropZone.into, branch: 'else')!.branch,
          'else');
    });

    test('空容器 into 追加到末尾', () {
      final rows = buildFlowOutline([
        FlowNode(key: 'empty', id: 'empty', kind: 'seq'),
        FlowNode(key: 't', id: 't', kind: 'task'),
      ]);
      final t = resolveDrop(rows, 't', 'empty', DropZone.into)!;
      expect(t.parentId, 'empty');
      expect(t.index, isNull);
      expect(t.branch, isNull);
    });

    test('拖进自身 / 子孙返回 null', () {
      final rows = buildFlowOutline([
        FlowNode(key: 'box', id: 'box', kind: 'seq', children: [
          FlowNode(key: 'inner', id: 'inner', kind: 'seq', children: [
            FlowNode(key: 'leaf', id: 'leaf', kind: 'task'),
          ]),
        ]),
        FlowNode(key: 'z', id: 'z', kind: 'task'),
      ]);
      expect(resolveDrop(rows, 'box', 'inner', DropZone.into), isNull);
      expect(resolveDrop(rows, 'box', 'leaf', DropZone.before), isNull);
      expect(resolveDrop(rows, 'inner', 'leaf', DropZone.into), isNull);
      expect(resolveDrop(rows, 'box', 'box', DropZone.into), isNull);
    });

    test('叶子不能 into', () {
      final rows = buildFlowOutline(chain());
      expect(resolveDrop(rows, 'a', 'b', DropZone.into), isNull);
    });

    test('branchesLabelled=false / canMove=false 时 if 不可落', () {
      final rows = buildFlowOutline([
        ..._ifTree(),
        FlowNode(key: 'z', id: 'z', kind: 'task'),
      ]);
      expect(
          resolveDrop(rows, 'z', 'pick', DropZone.into,
              branch: 'then', branchesLabelled: false),
          isNull);
      expect(
          resolveDrop(rows, 'z', 'pick', DropZone.into,
              branch: 'then', canMove: false),
          isNull);
      expect(
          resolveDrop(rows, 'a', 'z', DropZone.before, canMove: false), isNull);
    });

    test('branchesLabelled=false 时 if 分支内 before/after 也不可落', () {
      final rows = buildFlowOutline([
        ..._ifTree(),
        FlowNode(key: 'z', id: 'z', kind: 'task'),
      ]);
      // 旧主机不认 branch 标记：落在 if 子节点旁边同样会带 branch:'then'。
      expect(
        resolveDrop(rows, 'z', 't1', DropZone.before, branchesLabelled: false),
        isNull,
      );
      expect(
        resolveDrop(rows, 'z', 't2', DropZone.after, branchesLabelled: false),
        isNull,
      );
      expect(
        resolveDrop(rows, 'z', 'e1', DropZone.before, branchesLabelled: false),
        isNull,
      );
      // 新主机标了分支时照常放行。
      expect(resolveDrop(rows, 'z', 't1', DropZone.before)?.branch, 'then');
    });

    test('超过 maxDepth 层返回 null', () {
      final rows = buildFlowOutline(chain());
      expect(
          resolveDrop(rows, 'a', 'b', DropZone.before, maxDepth: -1), isNull);
    });
  });

  test('FlowOutlineOps.moveTo 生成一个 move op', () {
    final rows = buildFlowOutline([
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(key: 'c', id: 'c', kind: 'task'),
    ]);
    final t = resolveDrop(rows, 'a', 'c', DropZone.after)!;
    expect(FlowOutlineOps.moveTo(t), [
      {'op': 'move', 'node_id': 'a', 'parent_id': '', 'index': 1},
    ]);
  });
}
