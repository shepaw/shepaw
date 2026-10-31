import 'dart:convert';

import 'package:yaml/yaml.dart';

/// 从流程定义原文里取东西。App 平时不解析 YAML（节点树由 Hub 给），只在
/// 运行中改写时要拿出某个容器的子步骤——改完交回主机的是 JSON（`steps`）。
class FlowYaml {
  /// 这个节点的子步骤，格式化成 JSON 文本。找不到、或者它不是容器时返回 null
  /// （单个叶子要改请指向它所在的容器，F19 的口径）。
  static String? stepsJsonOf(String yaml, String nodeId) {
    final root = _plain(loadYaml(yaml));
    if (root is! Map) return null;
    final node = _find(root, nodeId);
    if (node == null) return null;
    final steps = _childrenOf(node);
    if (steps == null) return null;
    return const JsonEncoder.withIndent('  ').convert(steps);
  }

  /// 反过来：把用户改过的那段文本读回成步骤列表。不是列表就返回 null。
  static List<Map<String, dynamic>>? stepsFromJson(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! List) return null;
    return [
      for (final item in decoded)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// 容器里放子步骤的那个键。
  static List<Object?>? _childrenOf(Map<Object?, Object?> node) {
    // 最外层定义直接就是 `steps:`。
    final top = node['steps'];
    if (top is List) return top;
    for (final key in const ['seq', 'par', 'loop', 'map', 'if']) {
      final inner = node[key];
      if (inner is! Map) continue;
      for (final slot in const ['steps', 'then']) {
        final steps = inner[slot];
        if (steps is List) return steps;
      }
    }
    return null;
  }

  static Map<Object?, Object?>? _find(Map<Object?, Object?> node, String id) {
    if (node['id'] == id) return node;
    final steps = _childrenOf(node);
    if (steps != null) {
      for (final child in steps) {
        if (child is! Map) continue;
        final hit = _find(child, id);
        if (hit != null) return hit;
      }
    }
    // if 的另一支。
    for (final key in const ['seq', 'par', 'loop', 'map', 'if']) {
      final inner = node[key];
      if (inner is! Map) continue;
      final other = inner['else'];
      if (other is! List) continue;
      for (final child in other) {
        if (child is! Map) continue;
        final hit = _find(child, id);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// YamlMap / YamlList 换成普通的 Map / List，才好交给 `jsonEncode`。
  static Object? _plain(Object? value) {
    if (value is YamlMap || value is Map) {
      return {
        for (final entry in (value as Map).entries)
          entry.key.toString(): _plain(entry.value),
      };
    }
    if (value is YamlList || value is List) {
      return [for (final item in value as List) _plain(item)];
    }
    return value;
  }
}
