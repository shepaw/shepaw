import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_edit_ops.dart';

void main() {
  group('FlowEditOps', () {
    test('set 带上节点、字段路径和值；null 就是删掉这个键', () {
      expect(FlowEditOps.set('build', 'task.prompt', '做'),
          {'op': 'set', 'node_id': 'build', 'field': 'task.prompt', 'value': '做'});
      expect(FlowEditOps.set('build', 'desc', null),
          {'op': 'set', 'node_id': 'build', 'field': 'desc', 'value': null});
    });

    test('header 改的是定义头，点分路径也照发', () {
      expect(FlowEditOps.header('description', '先设计'),
          {'op': 'header', 'field': 'description', 'value': '先设计'});
      expect(FlowEditOps.header('limits.max_tasks', 30),
          {'op': 'header', 'field': 'limits.max_tasks', 'value': 30});
    });

    test('insert 不传 index 就是追加；if 的两个分支靠 branch 区分', () {
      expect(
        FlowEditOps.insert(parentId: '', step: const {}),
        {'op': 'insert', 'parent_id': '', 'step': const {}},
      );
      expect(
        FlowEditOps.insert(parentId: 'pick', index: 0, branch: 'else', step: const {}),
        {
          'op': 'insert',
          'parent_id': 'pick',
          'step': const {},
          'index': 0,
          'branch': 'else',
        },
      );
    });

    test('上移 / 下移：主机先摘再插，所以插到相邻下标就换了个位置', () {
      // 原来在 index 2，上移就是插到 1：摘掉自己后原来在 1 的那个还在 1。
      expect(
        FlowEditOps.move(nodeId: 'review', parentId: 'build', index: 1),
        {'op': 'move', 'node_id': 'review', 'parent_id': 'build', 'index': 1},
      );
      expect(
        FlowEditOps.move(nodeId: 'impl', parentId: 'build', index: 2),
        {'op': 'move', 'node_id': 'impl', 'parent_id': 'build', 'index': 2},
      );
      // 回到根层：parent_id 给空串。
      expect(
        FlowEditOps.move(nodeId: 'review', parentId: ''),
        {'op': 'move', 'node_id': 'review', 'parent_id': ''},
      );
    });

    test('缩进进 if 必须带 branch，且不能带 index', () {
      final op = FlowEditOps.move(nodeId: 'x', parentId: 'pick', branch: 'then');
      expect(op['branch'], 'then');
      expect(op.containsKey('index'), isFalse);
    });

    test('上一个兄弟是叶子时：先包成 seq 再挪进去，两个操作同一批', () {
      expect(
        FlowEditOps.indentIntoLeaf(
          nodeId: 'review',
          previousSiblingId: 'impl',
          wrapperId: 'wrap-1',
        ),
        [
          {
            'op': 'wrap',
            'node_id': 'impl',
            'kind': 'seq',
            'wrapper_id': 'wrap-1',
          },
          {'op': 'move', 'node_id': 'review', 'parent_id': 'wrap-1'},
        ],
      );
    });

    test('wrap 只在 loop 时带 max', () {
      expect(
        FlowEditOps.wrap(nodeId: 'a', kind: 'par', wrapperId: 'w'),
        {'op': 'wrap', 'node_id': 'a', 'kind': 'par', 'wrapper_id': 'w'},
      );
      expect(
        FlowEditOps.wrap(nodeId: 'a', kind: 'loop', wrapperId: 'w'),
        {
          'op': 'wrap',
          'node_id': 'a',
          'kind': 'loop',
          'wrapper_id': 'w',
          'max': 3,
        },
      );
    });

    test('改类型：子节点先挪出去，换完类型体再挪回来，id 不变', () {
      expect(
        FlowEditOps.changeKind(
          id: 'build',
          from: 'seq',
          to: 'par',
          parentId: '',
          index: 0,
          childIds: ['impl', 'review'],
        ),
        [
          {'op': 'move', 'node_id': 'impl', 'parent_id': '', 'index': 1},
          {'op': 'move', 'node_id': 'review', 'parent_id': '', 'index': 2},
          {'op': 'set', 'node_id': 'build', 'field': 'seq', 'value': null},
          {
            'op': 'set',
            'node_id': 'build',
            'field': 'par',
            'value': <String, dynamic>{},
          },
          {'op': 'move', 'node_id': 'impl', 'parent_id': 'build', 'index': 0},
          {'op': 'move', 'node_id': 'review', 'parent_id': 'build', 'index': 1},
        ],
      );
    });

    test('没有子节点时改类型就是一删一加', () {
      expect(
        FlowEditOps.changeKind(
          id: 'a',
          from: 'task',
          to: 'gate',
          parentId: '',
          index: 0,
        ),
        [
          {'op': 'set', 'node_id': 'a', 'field': 'task', 'value': null},
          {
            'op': 'set',
            'node_id': 'a',
            'field': 'gate',
            'value': {
              'ask': 'user',
              'options': ['ok', 'rework'],
            },
          },
        ],
      );
    });
  });

  group('FlowStepDefaults', () {
    test('必填字段给默认体，缺的会由主机产出诊断来提示', () {
      expect(FlowStepDefaults.body('loop'), {'max': 3});
      expect(FlowStepDefaults.body('if'), {'cond': 'true'});
      expect(FlowStepDefaults.body('gate'), {
        'ask': 'user',
        'options': ['ok', 'rework'],
      });
      expect(FlowStepDefaults.body('seq'), isEmpty);
    });

    test('step 把类型体挂在类型键下', () {
      expect(
        FlowStepDefaults.step('s1', 'task', prompt: '做'),
        {
          'id': 's1',
          'task': {'prompt': '做'},
        },
      );
    });

    test('能往里加子节点的才算容器；if 不能拆开', () {
      expect(FlowStepDefaults.isContainer('par'), isTrue);
      expect(FlowStepDefaults.isContainer('task'), isFalse);
      // 主机拆 if 会把 else 整支丢掉，所以不给这个按钮。
      expect(FlowStepDefaults.canUnwrap('if'), isFalse);
      expect(FlowStepDefaults.canUnwrap('loop'), isTrue);
    });
  });
}
