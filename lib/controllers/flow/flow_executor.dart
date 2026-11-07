import 'package:yaml/yaml.dart';

/// task 的执行者（方案 M4）。
///
/// 主机要求 `role` / `agent` / `uses` **三选一**（`validate` 会报「只能指定一个
/// 执行者」）。原方案对它们只给自由文本框，用户得手敲 `agent:<id>` —— 新建一
/// 步就带一条 error。这里收成一个「谁来做」，切换时把另外两个清掉。
enum FlowExecutorMode { unset, role, agent, she }

class FlowExecutor {
  const FlowExecutor._(this.mode, this.value);

  final FlowExecutorMode mode;

  /// 角色名或 Agent id。
  final String? value;

  static const unset = FlowExecutor._(FlowExecutorMode.unset, null);
  static const she = FlowExecutor._(FlowExecutorMode.she, null);

  static FlowExecutor role(String name) => FlowExecutor._(FlowExecutorMode.role, name);
  static FlowExecutor agent(String id) => FlowExecutor._(FlowExecutorMode.agent, id);

  static FlowExecutor of(Map<String, dynamic>? fields) {
    final task = fields?['task'];
    if (task is Map) {
      final role = task['role']?.toString() ?? '';
      if (role.isNotEmpty) return FlowExecutor.role(role);
      final agent = task['agent']?.toString() ?? '';
      if (agent.isNotEmpty) return FlowExecutor.agent(agent);
      final uses = task['uses']?.toString() ?? '';
      if (uses == 'she') return she;
      // `uses: agent:<id>` 引擎也认，按 Agent 呈现。
      if (uses.startsWith('agent:')) {
        return FlowExecutor.agent(uses.substring('agent:'.length));
      }
    }
    return unset;
  }

  /// 写回时要发的三个字段。没选中的那两个给 null（= 删掉）。
  Map<String, Object?> ops() => {
        'task.role': mode == FlowExecutorMode.role ? value : null,
        'task.agent': mode == FlowExecutorMode.agent ? value : null,
        'task.uses': mode == FlowExecutorMode.she ? 'she' : null,
      };

  /// 界面上显示什么。
  String label() => switch (mode) {
        FlowExecutorMode.role => value ?? '',
        FlowExecutorMode.agent => value ?? '',
        FlowExecutorMode.she => '惜宝',
        FlowExecutorMode.unset => '',
      };
}

/// 只读地看一眼定义头里的 `roles`，用来填「谁来做」的下拉。
///
/// App 原则上不解析 YAML —— 改动一律走主机的 header 操作。这里破例，**只读不
/// 写**：角色名单没有别的帧能拿到，读出来的东西也不会被回写进定义。读不动就
/// 返回空列表，下拉退化成没有候选项。
List<String> peekRoles(String yaml) {
  try {
    final doc = loadYaml(yaml);
    if (doc is! Map) return const [];
    final roles = doc['roles'];
    if (roles is! Map) return const [];
    return [for (final key in roles.keys) key.toString()];
  } catch (_) {
    return const [];
  }
}

/// 只读地看一眼定义里**真正要绑定 Agent** 的角色。
///
/// 主机只在执行到 `task.role` / `task.uses: role:<name>`（或 `plan.who` 写成
/// 角色名）的节点时查 `bindings`（`crates/api/src/flow/host.rs::resolve_target`）。
/// 头里 `roles:` 声明过、但节点后来全改成 `agent: <id>` 的角色根本用不上绑定：
/// 以前开跑表单按声明名单挨个要人选 Agent，用户把模板节点的执行者换完、保存，
/// 点运行还是被拦下来（玉简 f3eb35c1）。
///
/// 和 [peekRoles] 一样只读不写；解析不了就给空列表（主机那边也会先报校验错）。
/// 返回顺序以头里的声明顺序为准，手写了未声明角色的节点排在后面。
List<String> peekUsedRoles(String yaml) {
  Object? doc;
  try {
    doc = loadYaml(yaml);
  } catch (_) {
    return const [];
  }
  if (doc is! Map) return const [];
  final declared = peekRoles(yaml);
  final declaredSet = declared.toSet();
  final found = <String>{};
  // host.rs::judge_agent 对 plan.who 的 owner / user / she / agent:<id> 自己兜底，
  // 只有写成声明过的角色名才需要 bindings。
  const autoResolved = {'', 'owner', 'user', 'she'};

  void visit(Object? node) {
    if (node is Map) {
      final task = node['task'];
      if (task is Map) {
        final role = task['role'];
        if (role is String && role.trim().isNotEmpty) found.add(role.trim());
        final uses = task['uses'];
        if (uses is String && uses.trim().startsWith('role:')) {
          final fromUses = uses.trim().substring('role:'.length).trim();
          if (fromUses.isNotEmpty) found.add(fromUses);
        }
      }
      final plan = node['plan'];
      if (plan is Map) {
        final who = plan['who'];
        if (who is String &&
            declaredSet.contains(who.trim()) &&
            !autoResolved.contains(who.trim())) {
          found.add(who.trim());
        }
      }
      for (final value in node.values) {
        visit(value);
      }
    } else if (node is List) {
      for (final item in node) {
        visit(item);
      }
    }
  }

  // 只看步骤树：头里 `roles` / `outputs` 等映射也可能有名叫 role 的键，
  // 全文档扫键名会把输出字段名误认成角色。
  visit(doc['steps']);
  return [
    for (final role in declared)
      if (found.contains(role)) role,
    for (final role in found)
      if (!declaredSet.contains(role)) role,
  ];
}

/// 角色声明里的 `default`（模板自带的兜底 Agent id）。
///
/// 主机 `flow_start` 不会自动把 roles.*.default 灌进 bindings，所以开跑表单
/// 要预填、并随 `bindings` 一起发过去，否则模板写着默认 Agent 也照样要人手选。
Map<String, String> peekRoleDefaults(String yaml) {
  final out = <String, String>{};
  for (final entry in FlowHeaderPeek.raw(yaml, 'roles').entries) {
    final spec = entry.value;
    if (spec is! Map) continue;
    final agent = spec['default']?.toString().trim() ?? '';
    // `{{ inputs.x }}` 这类模板值主机不会当 Agent id 解析，别预填进去把
    // 原本能手选的绑定变成一条跑不起来的 bindings。
    if (agent.isEmpty || agent.contains('{{')) continue;
    out[entry.key] = agent;
  }
  return out;
}

/// 定义头里声明的一个输入。
class FlowInputSpec {
  const FlowInputSpec({
    required this.name,
    required this.type,
    required this.required,
    this.defaultValue,
  });

  final String name;
  final String type;
  final bool required;

  /// YAML 里的 `default`，原样当字符串用。
  final String? defaultValue;
}

/// 头部其余字段的只读窥探。和 [peekRoles] / [peekInputs] 一样只读不写。
class FlowHeaderPeek {
  FlowHeaderPeek._();

  static Map<String, dynamic> _root(String yaml) {
    try {
      final doc = loadYaml(yaml);
      return doc is Map ? Map<String, dynamic>.from(doc) : const {};
    } catch (_) {
      return const {};
    }
  }

  static String description(String yaml) =>
      _root(yaml)['description']?.toString() ?? '';

  static ({int maxTasks, String timeout}) limits(String yaml) {
    final raw = _root(yaml)['limits'];
    final map = raw is Map ? raw : const {};
    return (
      maxTasks: (map['max_tasks'] as num?)?.toInt() ?? 0,
      timeout: map['timeout']?.toString() ?? '',
    );
  }

  /// 顶层 `outputs`：`name → 模板字符串`。
  static Map<String, String> outputs(String yaml) {
    final raw = _root(yaml)['outputs'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  /// 原始头部映射。表单要拿它来「只替换改过的字段」，否则会把没显示的键
  /// （roles.desc、inputs.default、limits 里的额外键）整表抹掉。
  static Map<String, dynamic> raw(String yaml, String key) {
    final value = _root(yaml)[key];
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }
}

/// 只读地看一眼定义头里的 `inputs`，用来生成开跑表单。
///
/// 和 [peekRoles] 一样：只读不写，读不动就给空列表。
List<FlowInputSpec> peekInputs(String yaml) {
  Object? doc;
  try {
    doc = loadYaml(yaml);
  } catch (_) {
    return const [];
  }
  if (doc is! Map) return const [];
  final inputs = doc['inputs'];
  if (inputs is! Map) return const [];
  final out = <FlowInputSpec>[];
  for (final entry in inputs.entries) {
    final spec = entry.value;
    final map = spec is Map ? spec : const {};
    out.add(FlowInputSpec(
      name: entry.key.toString(),
      type: (map['type'] ?? 'string').toString(),
      required: map['required'] == true,
      defaultValue: map['default']?.toString(),
    ));
  }
  return out;
}
