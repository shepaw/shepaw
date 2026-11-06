import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_outline.dart';
import 'package:shepaw/controllers/flow/flow_references.dart';
import 'package:shepaw/peer/models/flow_models.dart';

void main() {
  final yaml =
      'flow: dev\ninputs:\n  goal: {type: string, required: true}\nsteps: []\n';

  test('只列当前节点之前的步骤，不列后面的', () {
    final tree = [
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(key: 'b', id: 'b', kind: 'task'),
      FlowNode(key: 'c', id: 'c', kind: 'task'),
    ];
    final refs = FlowReferences.of(
      tree: tree,
      currentNodeId: 'b',
      yaml: 'flow: x\n',
    );
    expect(refs, contains('{{ a.text }}'));
    expect(refs, isNot(contains('{{ b.text }}')));
    expect(refs, isNot(contains('{{ c.text }}')));
  });

  test('头部 inputs 列在最前面', () {
    final refs = FlowReferences.of(
      tree: [FlowNode(key: 'a', id: 'a', kind: 'task')],
      currentNodeId: 'a',
      yaml: yaml,
    );
    expect(refs.first, '{{ inputs.goal }}');
  });

  test('声明了 output 的步骤给 .data.<字段> 候选', () {
    final tree = [
      FlowNode(
        key: 'review',
        id: 'review',
        kind: 'task',
        fields: {
          'task': {
            'output': {
              'verdict': {
                'enum': ['pass', 'revise']
              },
              'comments': 'string',
            }
          }
        },
      ),
      FlowNode(key: 'next', id: 'next', kind: 'task'),
    ];
    final refs = FlowReferences.of(
      tree: tree,
      currentNodeId: 'next',
      yaml: 'flow: x\n',
    );
    expect(refs, contains('{{ review.text }}'));
    expect(refs, contains('{{ review.data.verdict }}'));
    expect(refs, contains('{{ review.data.comments }}'));
  });

  test('map / loop 里补特殊引用', () {
    final mapTree = [
      FlowNode(
        key: 'each',
        id: 'each',
        kind: 'map',
        children: [FlowNode(key: 'step', id: 'step', kind: 'task')],
      ),
    ];
    expect(
      FlowReferences.of(
          tree: mapTree, currentNodeId: 'step', yaml: 'flow: x\n'),
      contains('{{ item }}'),
    );

    final loopTree = [
      FlowNode(
        key: 'retry',
        id: 'retry',
        kind: 'loop',
        children: [FlowNode(key: 'work', id: 'work', kind: 'task')],
      ),
    ];
    expect(
      FlowReferences.of(
          tree: loopTree, currentNodeId: 'work', yaml: 'flow: x\n'),
      contains('{{ prev.text }}'),
    );
  });

  test('多层嵌套的 map / loop 祖先也能认出来', () {
    final tree = [
      FlowNode(
        key: 'each',
        id: 'each',
        kind: 'map',
        children: [
          FlowNode(
            key: 'seq',
            id: 'seq',
            kind: 'seq',
            children: [FlowNode(key: 'work', id: 'work', kind: 'task')],
          ),
        ],
      ),
    ];
    expect(
      FlowReferences.of(tree: tree, currentNodeId: 'work', yaml: 'flow: x\n'),
      contains('{{ item }}'),
    );
  });

  test('哪些字段给插入引用按钮', () {
    expect(FlowReferences.supports('task.prompt'), isTrue);
    expect(FlowReferences.supports('when'), isTrue);
    expect(FlowReferences.supports('loop.until'), isTrue);
    expect(FlowReferences.supports('desc'), isFalse);
  });

  group('refWarningsAfterMove', () {
    test('把被引用的步骤拖到引用方后面 → 前向引用预警', () {
      final tree = [
        FlowNode(key: 'a', id: 'a', kind: 'task'),
        FlowNode(
          key: 'b',
          id: 'b',
          kind: 'task',
          fields: {
            'task': {'prompt': '请结合 {{ a.text }} 来写'}
          },
        ),
      ];
      // a → b 之后：摘掉 a 再插到 index 1 → [b, a]。
      final target = FlowDropTarget(dragId: 'a', parentId: '', index: 1);
      final warnings = refWarningsAfterMove(tree, 'a', target);
      expect(warnings, isNotEmpty);
      expect(warnings.join('\n'), contains('a.text'));
    });

    test('没有断的引用不报警', () {
      final tree = [
        FlowNode(key: 'a', id: 'a', kind: 'task'),
        FlowNode(
          key: 'b',
          id: 'b',
          kind: 'task',
          fields: {
            'task': {'prompt': '{{ a.text }}'}
          },
        ),
      ];
      // b 移到 a 之前会断；但把 b 往后移到末尾（append）不会断。
      final unchanged = FlowDropTarget(dragId: 'b', parentId: '', index: 2);
      expect(refWarningsAfterMove(tree, 'b', unchanged), isEmpty);
    });

    test('{{ item }} 离开 map → 预警', () {
      final tree = [
        FlowNode(key: 'each', id: 'each', kind: 'map', children: [
          FlowNode(
            key: 'step',
            id: 'step',
            kind: 'task',
            fields: {
              'task': {'prompt': '处理 {{ item }}'}
            },
          ),
        ]),
        FlowNode(key: 'tail', id: 'tail', kind: 'task'),
      ];
      // 把 step 拖出 map，追加到根层。
      final target = FlowDropTarget(dragId: 'step', parentId: '', index: null);
      final warnings = refWarningsAfterMove(tree, 'step', target);
      expect(warnings, isNotEmpty);
      expect(warnings.join('\n'), contains('{{ item }}'));
    });

    test('{{ item.name }} 离开 map → 预警', () {
      final tree = [
        FlowNode(key: 'each', id: 'each', kind: 'map', children: [
          FlowNode(
            key: 'step',
            id: 'step',
            kind: 'task',
            fields: {
              'task': {'prompt': '处理 {{ item.name }}'}
            },
          ),
        ]),
        FlowNode(key: 'tail', id: 'tail', kind: 'task'),
      ];
      final target = FlowDropTarget(dragId: 'step', parentId: '', index: null);
      final warnings = refWarningsAfterMove(tree, 'step', target);
      expect(warnings, isNotEmpty);
      expect(warnings.join('\n'), contains('{{ item }}'));
    });

    test('拖回原容器的 into 区 → 不误报空容器', () {
      final tree = [
        FlowNode(key: 'seq', id: 'seq', kind: 'seq', children: [
          FlowNode(key: 'only', id: 'only', kind: 'task'),
        ]),
      ];
      // 落回同一个容器（into），容器还是有一个子节点，不会变空。
      final target = FlowDropTarget(dragId: 'only', parentId: 'seq', index: 0);
      final warnings = refWarningsAfterMove(tree, 'only', target);
      expect(
        warnings.where((w) => w.contains('empty container')),
        isEmpty,
        reason: '拖回原容器不该触发空容器预警：$warnings',
      );
      expect(warnings, isEmpty);
    });

    test('唯一子节点真的拖出容器 → 仍报空容器', () {
      final tree = [
        FlowNode(key: 'seq', id: 'seq', kind: 'seq', children: [
          FlowNode(key: 'only', id: 'only', kind: 'task'),
        ]),
      ];
      final target = FlowDropTarget(dragId: 'only', parentId: '', index: null);
      expect(
        refWarningsAfterMove(tree, 'only', target).join('\n'),
        contains('empty container'),
      );
    });

    test('prev.* 离开 loop → 预警', () {
      final tree = [
        FlowNode(key: 'retry', id: 'retry', kind: 'loop', children: [
          FlowNode(
            key: 'work',
            id: 'work',
            kind: 'task',
            fields: {
              'task': {'prompt': '改正 {{ prev.text }}'}
            },
          ),
        ]),
      ];
      final target = FlowDropTarget(dragId: 'work', parentId: '', index: null);
      final warnings = refWarningsAfterMove(tree, 'work', target);
      expect(warnings.join('\n'), contains('prev.*'));
    });
  });
}
