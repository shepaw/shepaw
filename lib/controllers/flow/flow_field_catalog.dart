import '../../peer/models/flow_field_schema.dart';
import '../../peer/models/flow_models.dart';

/// 客户端补充的字段表。
///
/// 主机 `flow_schema_resp` 的标签是给读 YAML 的人看的（「重开时」「会话
/// node/fresh/run」），不是给用户看的。所以：
/// - **标签、说明、枚举人话以客户端表为准**（更口语）；客户端没有的才用主机的；
/// - **枚举选项、字段形状以客户端表为准**，直到主机 schema 带上版本号；
/// - 主机没给的字段（含列表 / 映射 / 条件）由这里补上；
/// - 主机给了、但这张表没列到的字段一律落进「高级」，标签用主机的，不能丢掉。
class FlowFieldCatalog {
  FlowFieldCatalog._();

  static const Map<String, List<String>> groupOrder = {
    'task': ['what', 'who', 'when', 'output', 'advanced'],
    'par': ['join', 'when', 'advanced'],
    'loop': ['until', 'when', 'advanced'],
    'if': ['cond', 'advanced'],
    'map': ['over', 'when', 'advanced'],
    'gate': ['ask', 'show', 'options', 'advanced'],
    'set': ['vars', 'advanced'],
    'call': ['flow', 'where', 'advanced'],
    'plan': ['planWho', 'brief', 'advanced'],
    'seq': ['when', 'advanced'],
  };

  static List<String> groupsFor(String kind) =>
      groupOrder[kind] ?? const ['advanced'];

  static final Map<String, FlowFieldShape> _shapeOverrides = {
    'when': FlowFieldShape.cond,
    'loop.until': FlowFieldShape.cond,
    'loop.max': FlowFieldShape.intOrInput,
    'if.cond': FlowFieldShape.cond,
    'map.over': FlowFieldShape.cond,
    'call.flow': FlowFieldShape.flowRef,
    'task.model': FlowFieldShape.modelRef,
    'task.mode': FlowFieldShape.modeRef,
    'retry.backoff': FlowFieldShape.duration,
    'timeout': FlowFieldShape.duration,
  };

  static final Map<String, List<String>> _enumOverrides = {
    'par.on_fail': ['wait', 'cancel'],
    'par.join': ['all', 'any'],
    'loop.on_max': ['fail', 'continue'],
    'on_error': ['fail', 'continue'],
    'task.session': ['node', 'fresh', 'run'],
  };

  static const _sessionLabels = {
    'node': ('沿用上次', 'Reuse last'),
    'fresh': ('新会话', 'Fresh session'),
    'run': ('整次共用', 'Share for the run'),
  };
  static const _sessionHelp = {
    'node': ('沿用本步骤上次的会话', 'Continue this step\'s previous session'),
    'fresh': ('每次都开新会话', 'Start a new session every time'),
    'run': ('整次运行共用一个会话', 'One session for the whole run'),
  };
  static const _failContinue = {
    'fail': ('停下', 'Stop'),
    'continue': ('继续', 'Continue'),
  };
  static const _failContinueHelp = {
    'fail': ('整个流程停下', 'Stop the whole flow'),
    'continue': ('跳过这一步继续', 'Skip this step and continue'),
  };
  static const _onMaxHelp = {
    'fail': ('算失败', 'Count as failed'),
    'continue': ('当作完成继续', 'Treat as done and continue'),
  };

  static final Map<String, FlowFieldSpec> _client = {
    'task.prompt': const FlowFieldSpec(
      path: 'task.prompt',
      shape: FlowFieldShape.text,
      group: 'what',
      labelZh: '提示词',
      labelEn: 'Prompt',
      helpZh: '告诉执行者这一步要做什么。可以用 {{ }} 引用前面步骤的结果',
      helpEn:
          'What the executor should do. Use {{ }} to cite earlier results',
      required: true,
    ),
    'task.model': const FlowFieldSpec(
      path: 'task.model',
      shape: FlowFieldShape.modelRef,
      group: 'who',
      labelZh: '模型',
      labelEn: 'Model',
      helpZh: '不选就用这个 agent 自己的默认模型',
      helpEn: 'Leave empty to use the agent\'s own default model',
    ),
    'task.mode': const FlowFieldSpec(
      path: 'task.mode',
      shape: FlowFieldShape.modeRef,
      group: 'who',
      labelZh: '模式',
      labelEn: 'Mode',
    ),
    'task.output': const FlowFieldSpec(
      path: 'task.output',
      shape: FlowFieldShape.outputMap,
      group: 'output',
      labelZh: '结构化输出',
      labelEn: 'Structured output',
      helpZh: '要求执行者按固定字段返回，后面的步骤可以按字段引用',
      helpEn: 'Ask for fixed fields so later steps can cite them',
    ),
    'task.context': const FlowFieldSpec(
      path: 'task.context',
      shape: FlowFieldShape.listOf,
      group: 'output',
      labelZh: '额外参考',
      labelEn: 'Extra context',
      helpZh: '把这些步骤的结果也给执行者看',
      helpEn: 'Also show the executor these steps\' results',
    ),
    'task.session': const FlowFieldSpec(
      path: 'task.session',
      shape: FlowFieldShape.enumOf,
      group: 'advanced',
      labelZh: '会话',
      labelEn: 'Session',
      helpZh: '决定这一步是否记得之前的对话',
      helpEn: 'Whether this step remembers earlier conversation',
      options: ['node', 'fresh', 'run'],
      optionLabels: _sessionLabels,
      optionHelp: _sessionHelp,
      defaultValue: 'node',
    ),
    'task.on_restart': const FlowFieldSpec(
      path: 'task.on_restart',
      shape: FlowFieldShape.enumOf,
      group: 'advanced',
      labelZh: '重新运行时',
      labelEn: 'On restart',
      helpZh: '流程中断后重开，这一步怎么处理',
      helpEn: 'What to do with this step when a run is restarted',
      options: ['retry', 'ask', 'fail'],
      optionLabels: {
        'retry': ('再试一次', 'Try again'),
        'ask': ('问我', 'Ask me'),
        'fail': ('停下', 'Stop'),
      },
      optionHelp: {
        'retry': ('自动再跑这一步', 'Run this step again'),
        'ask': ('停下来问你', 'Stop and ask you'),
        'fail': ('把这一步算失败', 'Mark this step failed'),
      },
    ),
    'when': const FlowFieldSpec(
      path: 'when',
      shape: FlowFieldShape.cond,
      group: 'when',
      labelZh: '执行条件',
      labelEn: 'Run when',
      helpZh: '不满足时跳过这一步',
      helpEn: 'Skip this step when the condition is not met',
    ),
    'retry.max': const FlowFieldSpec(
      path: 'retry.max',
      shape: FlowFieldShape.int,
      group: 'advanced',
      labelZh: '失败重试',
      labelEn: 'Retries',
      helpZh: '失败后再试几次。0 表示不重试',
      helpEn: 'How many times to retry after a failure. 0 means no retry',
    ),
    'retry.backoff': const FlowFieldSpec(
      path: 'retry.backoff',
      shape: FlowFieldShape.duration,
      group: 'advanced',
      labelZh: '重试间隔',
      labelEn: 'Retry delay',
      helpZh: '例：30 秒、2 分钟',
      helpEn: 'Example: 30 seconds, 2 minutes',
    ),
    'timeout': const FlowFieldSpec(
      path: 'timeout',
      shape: FlowFieldShape.duration,
      group: 'advanced',
      labelZh: '超时',
      labelEn: 'Timeout',
      helpZh: '超过这个时间就算失败',
      helpEn: 'Fail if it takes longer than this',
    ),
    'on_error': const FlowFieldSpec(
      path: 'on_error',
      shape: FlowFieldShape.enumOf,
      group: 'advanced',
      labelZh: '出错时',
      labelEn: 'On error',
      options: ['fail', 'continue'],
      optionLabels: _failContinue,
      optionHelp: _failContinueHelp,
      defaultValue: 'fail',
    ),
    'par.join': const FlowFieldSpec(
      path: 'par.join',
      shape: FlowFieldShape.enumOf,
      group: 'join',
      labelZh: '等待方式',
      labelEn: 'Wait for',
      options: ['all', 'any'],
      optionLabels: {
        'all': ('全部完成', 'All finish'),
        'any': ('有一个就行', 'Any one'),
      },
      optionHelp: {
        'all': ('等全部完成', 'Wait until every branch finishes'),
        'any': ('任意一个完成就继续', 'Continue when any branch finishes'),
      },
      defaultValue: 'all',
    ),
    'par.on_fail': const FlowFieldSpec(
      path: 'par.on_fail',
      shape: FlowFieldShape.enumOf,
      group: 'join',
      labelZh: '有一个失败时',
      labelEn: 'If one fails',
      options: ['wait', 'cancel'],
      optionLabels: {
        'wait': ('等其他的', 'Wait for the rest'),
        'cancel': ('立刻取消', 'Cancel the rest'),
      },
      optionHelp: {
        'wait': ('等其他的跑完', 'Let the others finish'),
        'cancel': ('立刻取消其他的', 'Cancel the others immediately'),
      },
    ),
    'par.concurrency': const FlowFieldSpec(
      path: 'par.concurrency',
      shape: FlowFieldShape.int,
      group: 'advanced',
      labelZh: '同时最多几个',
      labelEn: 'At most at once',
      helpZh: '留空表示不限',
      helpEn: 'Leave empty for no limit',
    ),
    'loop.until': const FlowFieldSpec(
      path: 'loop.until',
      shape: FlowFieldShape.cond,
      group: 'until',
      labelZh: '直到',
      labelEn: 'Until',
      helpZh: '满足这个条件就停',
      helpEn: 'Stop when this becomes true',
    ),
    'loop.while': const FlowFieldSpec(
      path: 'loop.while',
      shape: FlowFieldShape.cond,
      group: 'until',
      labelZh: '只要',
      labelEn: 'While',
      helpZh: '这个条件一不满足就停',
      helpEn: 'Stop as soon as this is no longer true',
    ),
    'loop.max': const FlowFieldSpec(
      path: 'loop.max',
      shape: FlowFieldShape.intOrInput,
      group: 'until',
      labelZh: '最多几轮',
      labelEn: 'Max rounds',
      helpZh: '防止死循环',
      helpEn: 'Stops a loop that would never end',
      required: true,
    ),
    'loop.on_max': const FlowFieldSpec(
      path: 'loop.on_max',
      shape: FlowFieldShape.enumOf,
      group: 'advanced',
      labelZh: '跑满后',
      labelEn: 'When max is hit',
      options: ['fail', 'continue'],
      optionLabels: _failContinue,
      optionHelp: _onMaxHelp,
      defaultValue: 'fail',
    ),
    'if.cond': const FlowFieldSpec(
      path: 'if.cond',
      shape: FlowFieldShape.cond,
      group: 'cond',
      labelZh: '条件',
      labelEn: 'Condition',
      required: true,
    ),
    'map.over': const FlowFieldSpec(
      path: 'map.over',
      shape: FlowFieldShape.cond,
      group: 'over',
      labelZh: '对哪些数据',
      labelEn: 'Over',
      helpZh: '一个列表，每一项跑一遍里面的步骤',
      helpEn: 'A list. The inner steps run once per item',
      required: true,
    ),
    'map.as': const FlowFieldSpec(
      path: 'map.as',
      shape: FlowFieldShape.string,
      group: 'over',
      labelZh: '每一项叫',
      labelEn: 'Name each item',
      helpZh: '里面的步骤用 {{ 这个名字 }} 拿到当前项',
      helpEn: 'Inner steps read the current item as {{ this name }}',
      defaultValue: 'item',
    ),
    'map.concurrency': const FlowFieldSpec(
      path: 'map.concurrency',
      shape: FlowFieldShape.int,
      group: 'advanced',
      labelZh: '同时最多几个',
      labelEn: 'At most at once',
      helpZh: '留空表示不限',
      helpEn: 'Leave empty for no limit',
    ),
    'gate.ask': const FlowFieldSpec(
      path: 'gate.ask',
      shape: FlowFieldShape.enumOf,
      group: 'ask',
      labelZh: '问谁',
      labelEn: 'Ask',
      options: ['user', 'owner'],
      optionLabels: {
        'user': ('用户', 'User'),
        'owner': ('群主', 'Owner'),
      },
    ),
    'gate.show': const FlowFieldSpec(
      path: 'gate.show',
      shape: FlowFieldShape.string,
      group: 'show',
      labelZh: '给他看什么',
      labelEn: 'What to show',
    ),
    'gate.options': const FlowFieldSpec(
      path: 'gate.options',
      shape: FlowFieldShape.listOf,
      group: 'options',
      labelZh: '可选的回答',
      labelEn: 'Allowed answers',
      required: true,
    ),
    'set.vars': const FlowFieldSpec(
      path: 'set.vars',
      shape: FlowFieldShape.mapOf,
      group: 'vars',
      labelZh: '变量',
      labelEn: 'Variables',
      helpZh: '名字 → 表达式',
      helpEn: 'Name → expression',
    ),
    'call.flow': const FlowFieldSpec(
      path: 'call.flow',
      shape: FlowFieldShape.flowRef,
      group: 'flow',
      labelZh: '调用的流程',
      labelEn: 'Flow to call',
    ),
    'call.inputs': const FlowFieldSpec(
      path: 'call.inputs',
      shape: FlowFieldShape.mapOf,
      group: 'flow',
      labelZh: '传入参数',
      labelEn: 'Inputs',
    ),
    'call.group': const FlowFieldSpec(
      path: 'call.group',
      shape: FlowFieldShape.string,
      group: 'where',
      labelZh: '在哪个群执行',
      labelEn: 'Group',
      helpZh: '留空就在当前群',
      helpEn: 'Leave empty to stay in the current group',
    ),
    'plan.who': const FlowFieldSpec(
      path: 'plan.who',
      shape: FlowFieldShape.string,
      group: 'planWho',
      labelZh: '谁来规划',
      labelEn: 'Who plans',
    ),
    'plan.brief': const FlowFieldSpec(
      path: 'plan.brief',
      shape: FlowFieldShape.text,
      group: 'brief',
      labelZh: '规划要求',
      labelEn: 'Brief',
      required: true,
    ),
    'plan.allow': const FlowFieldSpec(
      path: 'plan.allow',
      shape: FlowFieldShape.listOf,
      group: 'brief',
      labelZh: '允许的步骤类型',
      labelEn: 'Allowed kinds',
    ),
    'plan.max_tasks': const FlowFieldSpec(
      path: 'plan.max_tasks',
      shape: FlowFieldShape.int,
      group: 'brief',
      labelZh: '最多几个任务',
      labelEn: 'Max tasks',
    ),
    'plan.context': const FlowFieldSpec(
      path: 'plan.context',
      shape: FlowFieldShape.listOf,
      group: 'advanced',
      labelZh: '额外参考',
      labelEn: 'Context',
    ),
    'plan.allow_empty': const FlowFieldSpec(
      path: 'plan.allow_empty',
      shape: FlowFieldShape.boolean,
      group: 'advanced',
      labelZh: '允许不派活',
      labelEn: 'Allow empty',
    ),
    'plan.data': const FlowFieldSpec(
      path: 'plan.data',
      shape: FlowFieldShape.outputMap,
      group: 'advanced',
      labelZh: '计划输出',
      labelEn: 'Plan output',
    ),
    'plan.session': const FlowFieldSpec(
      path: 'plan.session',
      shape: FlowFieldShape.enumOf,
      group: 'advanced',
      labelZh: '会话',
      labelEn: 'Session',
      options: ['node', 'fresh', 'run'],
      optionLabels: _sessionLabels,
      optionHelp: _sessionHelp,
      defaultValue: 'node',
    ),
  };

  static final Map<String, List<String>> _perKind = {
    'task': [
      'task.prompt',
      'task.model',
      'task.mode',
      'task.output',
      'task.context',
      'task.session',
      'task.on_restart',
    ],
    'par': ['par.join', 'par.on_fail', 'par.concurrency'],
    'loop': ['loop.max', 'loop.until', 'loop.while', 'loop.on_max'],
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
    'seq': <String>[],
  };

  static const _common = [
    'when',
    'retry.max',
    'retry.backoff',
    'timeout',
    'on_error',
  ];

  /// 合并后的字段规格。客户端表有的用客户端的标签和分组；没有的用主机标签，
  /// 分组落到「高级」。
  static List<FlowFieldSpec> specsFor(String kind, FlowSchema? schema) {
    if (schema == null) return const [];
    final result = <FlowFieldSpec>[];
    final seen = <String>{};

    for (final field in schema.fieldsFor(kind)) {
      seen.add(field.name);
      result.add(_resolve(field.name, hostLabel: field.label, host: field));
    }

    for (final path in [..._common, ...?_perKind[kind]]) {
      if (seen.contains(path)) continue;
      final spec = _client[path];
      if (spec == null) continue;
      seen.add(path);
      result.add(spec);
    }
    return result;
  }

  static FlowFieldSpec _resolve(
    String name, {
    required String hostLabel,
    required FlowSchemaField host,
  }) {
    final client = _client[name];
    if (client != null) return client;
    final shape = _shapeOverrides[name] ?? _shapeOf(host.type);
    final override = _enumOverrides[name];
    return FlowFieldSpec(
      path: name,
      shape: shape,
      group: 'advanced',
      labelZh: hostLabel,
      labelEn: name,
      options: shape == FlowFieldShape.enumOf
          ? (override ?? host.options)
          : const [],
    );
  }

  static FlowFieldShape _shapeOf(String type) => switch (type) {
        'text' => FlowFieldShape.text,
        'int' => FlowFieldShape.int,
        'enum' => FlowFieldShape.enumOf,
        _ => FlowFieldShape.string,
      };
}
