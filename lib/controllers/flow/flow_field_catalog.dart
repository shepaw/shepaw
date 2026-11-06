import '../../peer/models/flow_field_schema.dart';
import '../../peer/models/flow_models.dart';

/// 客户端补充的字段表（方案 M4）。
///
/// 主机 `flow_schema_resp` 只给了一部分字段，而且 `par.on_fail` 的选项曾经和引擎
/// 对不上（M1.5 修好了，但旧主机还会有错值）。所以：
/// - **标签和顺序**用主机的（它才是权威）；
/// - **枚举选项、字段形状以客户端表为准**，直到主机 schema 带上版本号；
/// - 主机没给的字段（含列表 / 映射 / 条件）由这里补上。
class FlowFieldCatalog {
  FlowFieldCatalog._();

  /// 主机给了这个字段、但形状要用客户端的（否则 `set` 出去的值类型不对）。
  static final Map<String, FlowFieldShape> _shapeOverrides = {
    'when': FlowFieldShape.cond,
    'loop.until': FlowFieldShape.cond,
    'loop.max': FlowFieldShape.intOrInput,
    'if.cond': FlowFieldShape.cond,
    'map.over': FlowFieldShape.cond,
    'call.flow': FlowFieldShape.flowRef,
    // 主机把这些当普通 string 给，界面要换成「选 agent 的可用模型 / 模式」的下拉。
    'task.model': FlowFieldShape.modelRef,
    'task.mode': FlowFieldShape.modeRef,
  };

  /// 主机 schema 里那些「类型对了但选项可能不对」的字段，用客户端选项覆盖。
  static final Map<String, List<String>> _enumOverrides = {
    'par.on_fail': ['wait', 'cancel'],
    'par.join': ['all', 'any'],
    'loop.on_max': ['fail', 'continue'],
    'on_error': ['fail', 'continue'],
    'task.session': ['node', 'fresh', 'run'],
  };

  /// 客户端独有字段：路径 → 规格。
  static final Map<String, FlowFieldSpec> _client = {
    'when': FlowFieldSpec(
      path: 'when',
      shape: FlowFieldShape.cond,
      labelZh: '条件（表达式 / 让人判断）',
      labelEn: 'Condition (expression / ask)',
    ),
    'retry.max': FlowFieldSpec(
      path: 'retry.max',
      shape: FlowFieldShape.int,
      labelZh: '最多重试',
      labelEn: 'Max retries',
    ),
    'retry.backoff': FlowFieldSpec(
      path: 'retry.backoff',
      shape: FlowFieldShape.string,
      labelZh: '重试间隔（如 30s）',
      labelEn: 'Retry backoff (e.g. 30s)',
    ),
    // task
    'task.uses': FlowFieldSpec(
        path: 'task.uses',
        shape: FlowFieldShape.string,
        labelZh: '执行者（agent:<id> 或 she）',
        labelEn: 'Executor (agent:<id> or she)'),
    'task.model': FlowFieldSpec(
        path: 'task.model',
        shape: FlowFieldShape.modelRef,
        labelZh: '模型',
        labelEn: 'Model'),
    'task.mode': FlowFieldSpec(
        path: 'task.mode',
        shape: FlowFieldShape.modeRef,
        labelZh: '模式',
        labelEn: 'Mode'),
    'task.on_restart': FlowFieldSpec(
        path: 'task.on_restart',
        shape: FlowFieldShape.enumOf,
        labelZh: '重开时',
        labelEn: 'On restart',
        options: ['retry', 'ask', 'fail']),
    'task.output': FlowFieldSpec(
        path: 'task.output',
        shape: FlowFieldShape.outputMap,
        labelZh: '结构化输出',
        labelEn: 'Structured output'),
    'task.context': FlowFieldSpec(
        path: 'task.context',
        shape: FlowFieldShape.listOf,
        labelZh: '额外上下文（步骤 id）',
        labelEn: 'Extra context (step ids)'),
    // containers
    'loop.max': FlowFieldSpec(
        path: 'loop.max',
        shape: FlowFieldShape.intOrInput,
        labelZh: '最多轮数',
        labelEn: 'Max rounds',
        required: true),
    'loop.until': FlowFieldSpec(
        path: 'loop.until',
        shape: FlowFieldShape.cond,
        labelZh: '直到（表达式）',
        labelEn: 'Until (expression)'),
    'loop.while': FlowFieldSpec(
        path: 'loop.while',
        shape: FlowFieldShape.cond,
        labelZh: '当（表达式）',
        labelEn: 'While (expression)'),
    'loop.on_max': FlowFieldSpec(
        path: 'loop.on_max',
        shape: FlowFieldShape.enumOf,
        labelZh: '跑满后',
        labelEn: 'On max',
        options: ['fail', 'continue']),
    'if.cond': FlowFieldSpec(
        path: 'if.cond',
        shape: FlowFieldShape.cond,
        labelZh: '条件',
        labelEn: 'Condition',
        required: true),
    'map.as': FlowFieldSpec(
        path: 'map.as',
        shape: FlowFieldShape.string,
        labelZh: '每一项叫',
        labelEn: 'Name each item'),
    'map.over': FlowFieldSpec(
        path: 'map.over',
        shape: FlowFieldShape.cond,
        labelZh: '对每一项',
        labelEn: 'Over',
        required: true),
    // gate / set / call / plan
    'gate.ask': FlowFieldSpec(
        path: 'gate.ask',
        shape: FlowFieldShape.enumOf,
        labelZh: '问谁',
        labelEn: 'Ask',
        options: ['user', 'owner']),
    'gate.show': FlowFieldSpec(
        path: 'gate.show',
        shape: FlowFieldShape.string,
        labelZh: '给你看的内容',
        labelEn: 'What to show'),
    'gate.options': FlowFieldSpec(
        path: 'gate.options',
        shape: FlowFieldShape.listOf,
        labelZh: '选项',
        labelEn: 'Options',
        required: true),
    'set.vars': FlowFieldSpec(
        path: 'set.vars',
        shape: FlowFieldShape.mapOf,
        labelZh: '变量（名 → 表达式）',
        labelEn: 'Variables (name → expression)'),
    'call.flow': FlowFieldSpec(
        path: 'call.flow',
        shape: FlowFieldShape.flowRef,
        labelZh: '子流程',
        labelEn: 'Subflow reference'),
    'call.group': FlowFieldSpec(
        path: 'call.group',
        shape: FlowFieldShape.string,
        labelZh: '调用的群',
        labelEn: 'Group to call'),
    'call.inputs': FlowFieldSpec(
        path: 'call.inputs',
        shape: FlowFieldShape.mapOf,
        labelZh: '子流程输入',
        labelEn: 'Subflow inputs'),
    'plan.who': FlowFieldSpec(
        path: 'plan.who',
        shape: FlowFieldShape.string,
        labelZh: '谁拆解',
        labelEn: 'Who plans'),
    'plan.brief': FlowFieldSpec(
        path: 'plan.brief',
        shape: FlowFieldShape.text,
        labelZh: '拆解说明',
        labelEn: 'Brief',
        required: true),
    'plan.allow': FlowFieldSpec(
        path: 'plan.allow',
        shape: FlowFieldShape.listOf,
        labelZh: '允许的节点类型',
        labelEn: 'Allowed kinds'),
    'plan.max_tasks': FlowFieldSpec(
        path: 'plan.max_tasks',
        shape: FlowFieldShape.int,
        labelZh: '最多派多少活',
        labelEn: 'Max tasks'),
    'plan.context': FlowFieldSpec(
        path: 'plan.context',
        shape: FlowFieldShape.listOf,
        labelZh: '上下文（步骤 id）',
        labelEn: 'Context (step ids)'),
    'plan.allow_empty': FlowFieldSpec(
        path: 'plan.allow_empty',
        shape: FlowFieldShape.boolean,
        labelZh: '允许不派活',
        labelEn: 'Allow empty'),
    'plan.data': FlowFieldSpec(
        path: 'plan.data',
        shape: FlowFieldShape.outputMap,
        labelZh: '计划输出',
        labelEn: 'Plan output'),
    'plan.session': FlowFieldSpec(
        path: 'plan.session',
        shape: FlowFieldShape.enumOf,
        labelZh: '会话',
        labelEn: 'Session',
        options: ['node', 'fresh', 'run']),
  };

  /// 按 kind 顺序要补哪些字段（不含主机已有的）。
  static final Map<String, List<String>> _perKind = {
    'task': [
      'task.uses',
      'task.model',
      'task.mode',
      'task.session',
      'task.on_restart',
      'task.output',
      'task.context',
    ],
    'par': ['par.join', 'par.on_fail', 'par.concurrency'],
    'loop': [
      'loop.max',
      'loop.until',
      'loop.while',
      'loop.on_max',
    ],
    'if': ['if.cond'],
    'map': ['map.over', 'map.as', 'map.concurrency'],
    'gate': ['gate.ask', 'gate.show', 'gate.options'],
    'set': ['set.vars'],
    'call': ['call.flow', 'call.group', 'call.inputs'],
    'plan': [
      'plan.who',
      'plan.brief',
      'plan.allow',
      'plan.max_tasks',
      'plan.context',
      'plan.allow_empty',
      'plan.data',
      'plan.session',
    ],
    'seq': [],
  };

  /// 合并后的字段规格。主机给的在前（顺序和标签以它为准），客户端独有的追加。
  static List<FlowFieldSpec> specsFor(String kind, FlowSchema? schema) {
    if (schema == null) return const [];
    final result = <FlowFieldSpec>[];
    final seen = <String>{};

    for (final field in schema.fieldsFor(kind)) {
      seen.add(field.name);
      final override = _enumOverrides[field.name];
      final shape = _shapeOverrides[field.name] ?? _shapeOf(field.type);
      result.add(FlowFieldSpec(
        path: field.name,
        shape: shape,
        labelZh: field.label,
        labelEn: field.name,
        options: shape == FlowFieldShape.enumOf
            ? (override ?? field.options)
            : const [],
        required: _client[field.name]?.required ?? false,
      ));
    }

    final paths = <String>[
      'when',
      'retry.max',
      'retry.backoff',
      ...?_perKind[kind],
    ];
    for (final path in paths) {
      if (seen.contains(path)) continue;
      final spec = _client[path];
      if (spec == null) continue; // 例如 call.flow / par.concurrency 由主机给
      result.add(spec);
    }
    return result;
  }

  static FlowFieldShape _shapeOf(String type) => switch (type) {
        'text' => FlowFieldShape.text,
        'int' => FlowFieldShape.int,
        'enum' => FlowFieldShape.enumOf,
        _ => FlowFieldShape.string,
      };
}
