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

/// 解析一次 YAML，给下面所有 peek 共用。读不动就给空 map（退回安全默认值）。
Map<dynamic, dynamic> _loadRoot(String yaml) {
  try {
    final doc = loadYaml(yaml);
    if (doc is Map) return Map<dynamic, dynamic>.from(doc);
  } catch (_) {
    // 主机那边也会先报校验错，这里只要别抛。
  }
  return const <dynamic, dynamic>{};
}

List<String> _peekRoleNames(Map doc) {
  final roles = doc['roles'];
  return roles is Map
      ? <String>[for (final key in roles.keys) key.toString()]
      : <String>[];
}

/// 只读地看一眼定义头里的 `roles`，用来填「谁来做」的下拉。
///
/// App 原则上不解析 YAML —— 改动一律走主机的 header 操作。这里破例，**只读不
/// 写**：角色名单没有别的帧能拿到，读出来的东西也不会被回写进定义。
List<String> peekRoles(String yaml) => _peekRoleNames(_loadRoot(yaml));

/// 开跑表单要用的头部信息，**一次解析 YAML** 拿齐。
///
/// 以前点一次「运行」要解析三四遍（角色扫描 / 角色默认值 / 表单页的 inputs）；
/// 现在 [FlowRunFormData.parse] 解析一次，结果直接传给开跑表单页。
class FlowRunFormData {
  const FlowRunFormData({
    required this.inputs,
    required this.roles,
    required this.roleDefaults,
  });

  /// 定义头声明的输入，用来生成表单字段。
  final List<FlowInputSpec> inputs;

  /// 开跑前要绑 Agent 的角色。
  final List<String> roles;

  /// `roles.*.default`，用来预填绑定。
  final Map<String, String> roleDefaults;

  /// [requiredRoles] 是新版主机在 `flow_get_resp` 里直接给出的名单（由主机从
  /// 解析后的 Definition 算出，见 `crates/api/src/flow/roles.rs`）。有就用它，
  /// 客户端不用再镜像主机的绑定解析规则；老主机没给这个字段时才退回本地的
  /// [peekUsedRoles] 保守扫描。
  factory FlowRunFormData.parse(String yaml, {List<String>? requiredRoles}) {
    final doc = _loadRoot(yaml);
    return FlowRunFormData(
      inputs: _peekInputs(doc),
      roles: requiredRoles ?? _peekUsedRoles(doc),
      roleDefaults: _peekRoleDefaults(doc),
    );
  }
}

/// 只读地看一眼定义里**可能要绑定 Agent** 的角色（老主机 / 离线兜底）。
///
/// 主机在几种地方查 `bindings`：`task.role` / `task.uses: role:` 走
/// `resolve_target`，`cond.judge` / `plan.who` 走 `judge_agent`
/// （`crates/api/src/flow/host.rs`）；后两者都是自由文本，主机新增用法时 App
/// 不该逐个镜像字段。所以这里反过来做**保守排除**：步骤树里任何字符串值只要
/// 等于声明过的角色名，就当它还要用；只有全流程一次都没出现过的角色才不问。
///
/// 头里 `roles:` 声明过、但节点后来全改成 `agent: <id>` 的角色因此不再拦着用户
/// （玉简 f3eb35c1）；没在 roles 里声明、却写在 `task.role` / `judge` / `who`
/// 上的名字也会问，免得主机开跑后找不到 Agent。
///
/// 返回顺序以头里的声明顺序为准，手写了未声明角色的节点排在后面。
List<String> peekUsedRoles(String yaml) => _peekUsedRoles(_loadRoot(yaml));

List<String> _peekUsedRoles(Map doc) {
  final declared = _peekRoleNames(doc);
  final declaredSet = declared.toSet();
  final found = <String>{};

  // host.rs::judge_agent 只兜底空串 / owner / agent:<id>；`user`、`she`
  // 都不是保留字，写成角色名时照样要 bindings。
  bool autoResolved(String who) =>
      who.isEmpty || who == 'owner' || who.startsWith('agent:');

  void visit(Object? node) {
    if (node is Map) {
      // 声明过的角色名以「值」出现在 steps 任意位置（`task.role`、
      // `when.judge`、`plan.who`，以及以后新增的字段）都算还在用。
      for (final value in node.values) {
        if (value is String) {
          final text = value.trim();
          if (declaredSet.contains(text) && !autoResolved(text)) {
            found.add(text);
          }
        }
      }
      // 没声明过的角色引用：主机同样会拿这个名字查 bindings。
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
      for (final key in const ['judge', 'who']) {
        final who = node[key];
        if (who is String && !autoResolved(who.trim())) {
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
Map<String, String> peekRoleDefaults(String yaml) =>
    _peekRoleDefaults(_loadRoot(yaml));

Map<String, String> _peekRoleDefaults(Map doc) {
  final out = <String, String>{};
  final raw = doc['roles'];
  if (raw is! Map) return out;
  for (final entry in raw.entries) {
    final spec = entry.value;
    if (spec is! Map) continue;
    final agent = spec['default']?.toString().trim() ?? '';
    // `{{ inputs.x }}` 这类模板值主机不会当 Agent id 解析，别预填进去把
    // 原本能手选的绑定变成一条跑不起来的 bindings。
    if (agent.isEmpty || agent.contains('{{')) continue;
    out[entry.key.toString()] = agent;
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

/// 输入框里的默认值写回 YAML。
///
/// 字没改过就返回 [previous]，bool、列表、数字都保持原来的类型。
/// 空字符串返回 null，调用方删掉这个键。
Object? flowInputDefaultForForm(Object? previous, String text, String type) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (previous != null && trimmed == previous.toString()) return previous;
  switch (type) {
    case 'int':
      return num.tryParse(trimmed) ?? trimmed;
    case 'bool':
      if (trimmed == 'true') return true;
      if (trimmed == 'false') return false;
      return trimmed;
    default:
      return trimmed;
  }
}

/// 只读地看一眼定义头里的 `inputs`，用来生成开跑表单。
///
/// 和 [peekRoles] 一样：只读不写，读不动就给空列表。
List<FlowInputSpec> peekInputs(String yaml) => _peekInputs(_loadRoot(yaml));

List<FlowInputSpec> _peekInputs(Map doc) {
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
