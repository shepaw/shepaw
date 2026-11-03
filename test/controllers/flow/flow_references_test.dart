import 'package:flutter_test/flutter_test.dart';
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
              'verdict': {'enum': ['pass', 'revise']},
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

  test('哪些字段给插入引用按钮', () {
    expect(FlowReferences.supports('task.prompt'), isTrue);
    expect(FlowReferences.supports('when'), isTrue);
    expect(FlowReferences.supports('loop.until'), isTrue);
    expect(FlowReferences.supports('desc'), isFalse);
  });
}
