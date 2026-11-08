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

    test('A5-8 断掉的是 .data 引用时，提示保留用户写的表达式', () {
      final tree = [
        FlowNode(key: 'a', id: 'a', kind: 'task'),
        FlowNode(
          key: 'b',
          id: 'b',
          kind: 'task',
          fields: {
            'task': {'prompt': '请根据 {{ a.data.rows }} 来写'}
          },
        ),
      ];
      // a → b 之后：引用跑到引用方后面，断掉。
      final target = FlowDropTarget(dragId: 'a', parentId: '', index: 1);
      final warnings = refWarningsAfterMove(tree, 'a', target);
      expect(warnings, isNotEmpty);
      expect(warnings.join('\n'), contains('{{ a.data.rows }}'),
          reason: '预警要指回用户真正写的字段');
      expect(warnings.join('\n'), isNot(contains('{{ a.text }}')),
          reason: '不能凭空把引用改写成 .text');
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

    test('A6-10: 同一 par 内换位置不报 join/write，外面拖进 par 仍报', () {
      final tree = [
        FlowNode(
          key: 'par',
          id: 'par',
          kind: 'par',
          children: const [
            FlowNode(key: 'a', id: 'a', kind: 'task'),
            FlowNode(key: 'b', id: 'b', kind: 'task'),
          ],
        ),
        FlowNode(key: 'outside', id: 'outside', kind: 'task'),
      ];
      final inside = FlowDropTarget(dragId: 'a', parentId: 'par', index: 1);
      expect(refWarningsAfterMove(tree, 'a', inside), isEmpty,
          reason: 'par 内从 index 0 拖到 1 没改变并行关系');

      final fromOutside =
          FlowDropTarget(dragId: 'outside', parentId: 'par', index: 0);
      expect(refWarningsAfterMove(tree, 'outside', fromOutside).join('\n'),
          contains('par par (join/write)'),
          reason: '从外部拖进 par 仍要提示 join / 变量写冲突');
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

    test('A8-9: then 末尾的越界 index 按主机语义插在 else 之前', () {
      final tree = [
        FlowNode(key: 'cond', id: 'cond', kind: 'if', children: const [
          FlowNode(key: 'a', id: 'a', kind: 'task', branch: 'then'),
          FlowNode(key: 'b', id: 'b', kind: 'task', branch: 'else'),
        ]),
        FlowNode(
          key: 'x',
          id: 'x',
          kind: 'task',
          fields: {
            'task': {'prompt': '结合 {{ b.text }} 继续'}
          },
        ),
      ];
      // 主机把 index=1 当作 then 数组内下标（越界夹到 then 末尾），
      // 结果顺序 [a, x, b]：x 对 b 的前向引用应该报警。旧模拟器会放到
      // [a, b, x]，把预警算没。
      final thenEnd = FlowDropTarget(
        dragId: 'x',
        parentId: 'cond',
        index: 1,
        branch: 'then',
      );
      expect(refWarningsAfterMove(tree, 'x', thenEnd).join('\n'),
          contains('{{ b.text }}'));

      // 越界的 else index 夹到 else 末尾：[a, b, x]，顺序没坏，不该误报。
      final elseEnd = FlowDropTarget(
        dragId: 'x',
        parentId: 'cond',
        index: 5,
        branch: 'else',
      );
      expect(refWarningsAfterMove(tree, 'x', elseEnd), isEmpty);
    });
  });

  test('输入和角色的引用按步骤列出来', () {
    final tree = [
      FlowNode(
        key: 'build',
        id: 'build',
        kind: 'task',
        fields: {
          'task': {
            'role': 'reviewer',
            'prompt': '发布 {{ inputs.version }}',
          },
        },
      ),
      FlowNode(
        key: 'tag',
        id: 'tag',
        kind: 'task',
        fields: {
          'task': {'prompt': '{{ inputs.version }} 打标签'},
        },
      ),
    ];
    expect(FlowHeaderUsage.inputs(tree)['version'], ['build', 'tag']);
    expect(FlowHeaderUsage.roles(tree)['reviewer'], ['build']);
    expect(FlowHeaderUsage.inputs(tree)['missing'], isNull);
  });
}
