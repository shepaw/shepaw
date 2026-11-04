import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_field_catalog.dart';
import 'package:shepaw/peer/models/flow_field_schema.dart';
import 'package:shepaw/peer/models/flow_models.dart';

void main() {
  FlowSchema _host() => FlowSchema.fromResponse({
        'success': true,
        'common': [
          {'name': 'desc', 'type': 'string', 'label': '说明'},
        ],
        'kinds': {
          'task': [
            {'name': 'task.prompt', 'type': 'text', 'label': '提示词'},
            {
              'name': 'task.session',
              'type': 'enum',
              'options': ['bad-option'],
              'label': '会话',
            },
          ],
          'par': [
            {
              'name': 'par.on_fail',
              'type': 'enum',
              'options': ['fail', 'continue'],
              'label': '分支失败时',
            },
          ],
        },
        'ops': [],
      })!;

  test('主机的标签和顺序在前，客户端独有的补在后面', () {
    final specs = FlowFieldCatalog.specsFor('task', _host());
    final paths = specs.map((s) => s.path).toList();
    expect(paths.first, 'desc');
    expect(paths, contains('task.prompt'));
    expect(paths, contains('task.uses'));
    expect(paths, contains('task.output'));
    expect(paths, contains('task.context'));
    expect(paths, contains('when'));
    expect(paths.indexOf('desc'), lessThan(paths.indexOf('task.uses')));
    expect(paths.where((p) => p == 'desc').length, 1);
    // 标签仍用主机的。
    final desc = specs.firstWhere((s) => s.path == 'desc');
    expect(desc.labelZh, '说明');
  });

  test('枚举选项以客户端为准：旧主机的错选项被覆盖', () {
    final par = FlowFieldCatalog.specsFor('par', _host());
    final onFail = par.firstWhere((s) => s.path == 'par.on_fail');
    expect(onFail.shape, FlowFieldShape.enumOf);
    expect(onFail.options, ['wait', 'cancel']);

    final task = FlowFieldCatalog.specsFor('task', _host());
    final session = task.firstWhere((s) => s.path == 'task.session');
    expect(session.options, ['node', 'fresh', 'run']);
  });

  test('主机给了的字段，形状也能按客户端覆盖', () {
    final loop = FlowFieldCatalog.specsFor('loop', _host());
    // 即使主机只给了普通 int，loop.max 也要是 intOrInput。
    final max = loop.where((s) => s.path == 'loop.max');
    expect(max, isNotEmpty);
    expect(max.first.shape, FlowFieldShape.intOrInput);
    expect(max.first.required, isTrue);
  });

  test('非标量字段都有对应的形状', () {
    final cases = {
      'task': {
        'task.output': FlowFieldShape.outputMap,
        'task.context': FlowFieldShape.listOf,
      },
      'gate': {
        'gate.options': FlowFieldShape.listOf,
      },
      'set': {
        'set.vars': FlowFieldShape.mapOf,
      },
      'call': {
        'call.inputs': FlowFieldShape.mapOf,
      },
      'plan': {
        'plan.allow': FlowFieldShape.listOf,
        'plan.allow_empty': FlowFieldShape.boolean,
        'plan.data': FlowFieldShape.outputMap,
      },
    };
    for (final entry in cases.entries) {
      final specs = FlowFieldCatalog.specsFor(entry.key, _host());
      for (final shape in entry.value.entries) {
        final found = specs.where((s) => s.path == shape.key);
        expect(found, isNotEmpty, reason: '${entry.key}.${shape.key}');
        expect(found.first.shape, shape.value,
            reason: '${entry.key}.${shape.key}');
      }
    }
  });

  test('cond 形状用于表达式字段', () {
    final specs = <FlowFieldSpec>[
      ...FlowFieldCatalog.specsFor('loop', _host()),
      ...FlowFieldCatalog.specsFor('if', _host()),
    ];
    for (final path in ['when', 'loop.until', 'loop.while', 'if.cond']) {
      final found = specs.where((s) => s.path == path);
      expect(found, isNotEmpty, reason: path);
      expect(found.first.shape, FlowFieldShape.cond, reason: path);
    }
  });

  test('schema 为空时不炸', () {
    expect(FlowFieldCatalog.specsFor('task', null), isEmpty);
  });
}
