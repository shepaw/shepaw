import '../../peer/models/flow_models.dart';

/// 客户端补充的字段表（方案 M4）。
///
/// 主机 `flow_schema_resp` 只给了一部分字段，而且 `par.on_fail` 的选项曾经和引擎
/// 对不上（M1.5 修好了，但旧主机还会有错值）。所以：
/// - **标签和顺序**用主机的（它才是权威）；
/// - **枚举选项以客户端表为准**，直到主机 schema 带上版本号；
/// - 主机没给的字段由这里补上。
///
/// 只补标量（string / text / int / enum）。`output` / `vars` / `options` / `inputs`
/// 这些映射和列表需要专门的表单控件，留给后续 —— 现在至少不用手敲大部分表达式。
class FlowFieldCatalog {
  FlowFieldCatalog._();

  /// 一份字段说明：点分路径 → 类型 / 选项 / 中文标签。
  static final Map<String, _Spec> _client = {
    // 公共字段
    'when': _Spec('string', '条件（表达式）'),
    'retry.max': _Spec('int', '最多重试'),
    'retry.backoff': _Spec('string', '重试间隔（如 30s）'),
    // task
    'task.uses': _Spec('string', '执行者（agent:<id> 或 she）'),
    'task.model': _Spec('string', '模型'),
    'task.mode': _Spec('string', '模式'),
    'task.on_restart': _Spec('enum', '重开时', ['retry', 'ask', 'fail']),
    // loop / if / map
    'loop.while': _Spec('string', '当（表达式）'),
    'loop.on_max': _Spec('enum', '跑满后', ['fail', 'continue']),
    'if.cond': _Spec('string', '条件'),
    'map.as': _Spec('string', '每一项叫'),
    'map.over': _Spec('string', '对每一项'),
    // gate / call / plan / set
    'gate.ask': _Spec('enum', '问谁', ['user', 'owner']),
    'gate.show': _Spec('string', '给你看的内容'),
    'call.group': _Spec('string', '调用的群'),
    'plan.who': _Spec('string', '谁拆解'),
    'plan.brief': _Spec('text', '拆解说明'),
    'plan.session': _Spec('enum', '会话', ['node', 'fresh', 'run']),
  };

  /// 按 kind 顺序要补哪些字段（不含主机已有的）。
  static final Map<String, List<String>> _perKind = {
    'task': [
      'task.uses',
      'task.model',
      'task.mode',
      'task.session',
      'task.on_restart',
    ],
    'par': ['par.join', 'par.on_fail', 'par.concurrency'],
    'loop': ['loop.max', 'loop.until', 'loop.while', 'loop.on_max'],
    'if': ['if.cond'],
    'map': ['map.over', 'map.as', 'map.concurrency'],
    'gate': ['gate.ask', 'gate.show'],
    'set': [],
    'call': ['call.flow', 'call.group'],
    'plan': ['plan.who', 'plan.brief', 'plan.session'],
    'seq': [],
  };

  /// 主机 schema 里那些「类型对了但选项可能不对」的字段，用客户端选项覆盖。
  static final Map<String, List<String>> _enumOverrides = {
    'par.on_fail': ['wait', 'cancel'],
    'par.join': ['all', 'any'],
    'loop.on_max': ['fail', 'continue'],
    'on_error': ['fail', 'continue'],
    'task.session': ['node', 'fresh', 'run'],
  };

  /// 合并后的字段表。
  ///
  /// 主机给的字段在前（顺序和标签以它为准），客户端独有的追加在后面。
  static List<FlowSchemaField> fieldsFor(String kind, FlowSchema? schema) {
    if (schema == null) return const [];
    final result = <FlowSchemaField>[];
    final seen = <String>{};

    for (final field in schema.fieldsFor(kind)) {
      seen.add(field.name);
      final override = _enumOverrides[field.name];
      if (override != null && field.type == 'enum') {
        result.add(FlowSchemaField(
          name: field.name,
          type: field.type,
          label: field.label,
          options: override,
        ));
      } else {
        result.add(field);
      }
    }

    // 公共字段和该类型的独有字段都补上（主机没给过的）。
    final paths = <String>[
      'when',
      'retry.max',
      'retry.backoff',
      ...?_perKind[kind],
    ];
    for (final path in paths) {
      if (seen.contains(path)) continue;
      final spec = _client[path];
      if (spec == null) continue;
      result.add(FlowSchemaField(
        name: path,
        type: spec.type,
        label: spec.label,
        options: spec.options,
      ));
    }
    return result;
  }
}

class _Spec {
  const _Spec(this.type, this.label, [this.options = const []]);

  final String type;
  final String label;
  final List<String> options;
}
