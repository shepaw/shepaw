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
    // 执行者改成检查器顶部的专用选择器，不再混在普通字段里（169d2579）。
    expect(paths, isNot(contains('task.uses')));
    expect(paths, contains('task.output'));
    expect(paths, contains('task.context'));
    expect(paths, contains('when'));
    // 主机给的字段在前，客户端独有的补在后面；拿客户端补的字段来验顺序。
    expect(paths.indexOf('desc'), lessThan(paths.indexOf('when')));
    expect(paths.indexOf('task.session'),
        lessThan(paths.indexOf('task.output')));
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

  test('call.flow 是流程库选择器，不是自由文本框', () {
    final call = FlowFieldCatalog.specsFor('call', _host());
    final flow = call.where((s) => s.path == 'call.flow');
    expect(flow, isNotEmpty);
    expect(flow.first.shape, FlowFieldShape.flowRef);
  });

  test('schema 为空时不炸', () {
    expect(FlowFieldCatalog.specsFor('task', null), isEmpty);
  });

  test('task.model / task.mode 换成 modelRef / modeRef（主机没给时）', () {
    final task = FlowFieldCatalog.specsFor('task', _host());
    expect(task.firstWhere((s) => s.path == 'task.model').shape,
        FlowFieldShape.modelRef);
    expect(task.firstWhere((s) => s.path == 'task.mode').shape,
        FlowFieldShape.modeRef);
  });

  test('主机把 model / mode 当 string 给也要覆盖成下拉形状', () {
    final host = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {
        'task': [
          {'name': 'task.model', 'type': 'string', 'label': '模型'},
          {'name': 'task.mode', 'type': 'string', 'label': '模式'},
        ],
      },
      'ops': [],
    })!;
    final task = FlowFieldCatalog.specsFor('task', host);
    expect(task.firstWhere((s) => s.path == 'task.model').shape,
        FlowFieldShape.modelRef);
    expect(task.firstWhere((s) => s.path == 'task.mode').shape,
        FlowFieldShape.modeRef);
    // 标签仍用主机的。
    expect(task.firstWhere((s) => s.path == 'task.model').labelZh, '模型');
  });

  test('modelRef / modeRef 的模板串值合法，空值也合法', () {
    const spec = FlowFieldSpec(
      path: 'task.model',
      shape: FlowFieldShape.modelRef,
      labelZh: '模型',
      labelEn: 'Model',
    );
    expect(isFlowFieldValueValid(spec, 'gpt-4'), isTrue);
    expect(isFlowFieldValueValid(spec, '{{ inputs.model }}'), isTrue);
    expect(isFlowFieldValueValid(spec, null), isTrue);
  });
}
