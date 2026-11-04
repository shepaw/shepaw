import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_host_caps.dart';
import 'package:shepaw/peer/models/flow_models.dart';

FlowSchema _schema(List<String> ops) => FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
      'ops': ops,
    })!;

const _ops = [
  'set',
  'insert',
  'move',
  'delete',
  'wrap',
  'unwrap',
  'retype',
  'header',
];

void main() {
  test('混合标注：任一 if 的子节点没标 branch 就整页降级', () {
    final tree = [
      FlowNode(
        key: 'a',
        id: 'a',
        kind: 'seq',
        children: [
          FlowNode(
            key: 'i1',
            id: 'i1',
            kind: 'if',
            children: [
              FlowNode(key: 't', id: 't', kind: 'task', branch: 'then'),
            ],
          ),
        ],
      ),
      FlowNode(
        key: 'i2',
        id: 'i2',
        kind: 'if',
        children: [FlowNode(key: 'e', id: 'e', kind: 'task')],
      ),
    ];
    final caps = FlowHostCaps.of(_schema(_ops), tree);
    expect(caps.canEdit, isTrue);
    // 只看第一个 if 会误判成 true，于是对 i2 放开结构操作（跨分支）。
    expect(caps.branchesLabelled, isFalse);
  });

  test('全部标注过才算有标记', () {
    final tree = [
      FlowNode(
        key: 'i',
        id: 'i',
        kind: 'if',
        children: [
          FlowNode(key: 't', id: 't', kind: 'task', branch: 'then'),
          FlowNode(key: 'e', id: 'e', kind: 'task', branch: 'else'),
        ],
      ),
    ];
    expect(FlowHostCaps.of(_schema(_ops), tree).branchesLabelled, isTrue);
  });
}
