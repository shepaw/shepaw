import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_field_catalog.dart';
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
    final fields = FlowFieldCatalog.fieldsFor('task', _host());
    final names = fields.map((f) => f.name).toList();
    expect(names.first, 'desc');
    expect(names, contains('task.prompt'));
    // 客户端补的字段在后面。
    expect(names, contains('task.uses'));
    expect(names, contains('task.on_restart'));
    expect(names, contains('when'));
    expect(names.indexOf('desc'), lessThan(names.indexOf('task.uses')));
    // 不重复主机已有的。
    expect(names.where((n) => n == 'desc').length, 1);
  });

  test('枚举选项以客户端为准：旧主机的错选项被覆盖', () {
    final par = FlowFieldCatalog.fieldsFor('par', _host());
    final onFail = par.firstWhere((f) => f.name == 'par.on_fail');
    // 引擎只认 wait / cancel，旧主机给的是 fail / continue。
    expect(onFail.options, ['wait', 'cancel']);
    expect(onFail.label, '分支失败时'); // 标签仍用主机的

    final task = FlowFieldCatalog.fieldsFor('task', _host());
    final session = task.firstWhere((f) => f.name == 'task.session');
    expect(session.options, ['node', 'fresh', 'run']);
  });

  test('客户端独有字段带上正确的类型', () {
    final task = FlowFieldCatalog.fieldsFor('task', _host());
    final uses = task.firstWhere((f) => f.name == 'task.uses');
    expect(uses.type, 'string');
    final restart = task.firstWhere((f) => f.name == 'task.on_restart');
    expect(restart.type, 'enum');
    expect(restart.options, ['retry', 'ask', 'fail']);
    expect(restart.label.isNotEmpty, isTrue);
  });

  test('schema 为空时不炸', () {
    expect(FlowFieldCatalog.fieldsFor('task', null), isEmpty);
  });
}
