import 'package:yaml/yaml.dart';

import '../../peer/models/flow_models.dart';

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
