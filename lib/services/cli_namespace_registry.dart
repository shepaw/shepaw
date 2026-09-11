import '../clis/cli_base.dart';
import '../clis/shepaw/shepaw_cli.dart';

/// 定义 CLI 命名空间的元数据
class CliNamespaceInfo {
  final String id;           // 命名空间 ID（如 'context'）
  final String label;        // 显示名称
  final String description;  // 描述
  final List<String> commands; // 该命名空间下的所有命令 ID（如 ['context.profile.query', 'context.profile.update']）

  const CliNamespaceInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.commands,
  });
}

/// CLI 命令注册表 —— 面向 UI 的命名空间 / 命令视图。
///
/// **不持有自己的命名空间列表**：唯一事实来源是
/// [ShepawCLI.instance.namespaces]。此前这里硬编码 11 项，与 ShepawCLI 的
/// 14 项漂移（缺 `os` / `workflow` / `store`），导致命令选择器静默丢弃这三个
/// 命名空间。改为派生后不可能再漂移。
///
/// 惰性重建（每次读取都从 [ShepawCLI.namespaces] 重建）而非缓存：外部工具
/// 会在 [ShepawCLI.reloadExternalTools] 里增删命名空间，而遍历 100 多条命令
/// 只发生在 UI 打开注册表视图时，成本可接受——比手工 `invalidate()` 更难忘记。
class CliNamespaceRegistry {
  CliNamespaceRegistry._();
  static final CliNamespaceRegistry instance = CliNamespaceRegistry._();

  /// 显示名称：命名空间 id 首字母大写（`context` → `Context`）。
  ///
  /// 旧实现手工维护字符串，但全部等于该规则，派生无信息损失。
  static String labelFor(String namespaceId) {
    if (namespaceId.isEmpty) return namespaceId;
    return namespaceId[0].toUpperCase() + namespaceId.substring(1);
  }

  /// 所有可用的顶层命名空间及其命令（内置 + 外部工具）。
  ///
  /// 结构：`{'context': CliNamespaceInfo(id: 'context', label: 'Context', ...)}`
  Map<String, CliNamespaceInfo> get namespaces => {
        for (final entry in ShepawCLI.instance.namespaces.entries)
          entry.key: CliNamespaceInfo(
            id: entry.key,
            label: labelFor(entry.key),
            description: entry.value.description,
            commands: _getAllCommandsInNamespace(entry.key, entry.value),
          ),
      };

  /// 递归获取命名空间中的所有命令 ID
  /// 支持嵌套命名空间（如 context.profile.*)
  static List<String> _getAllCommandsInNamespace(
    String namespaceId,
    CliNamespace namespace,
  ) {
    final commands = <String>[];

    // 添加该级别的直接命令
    for (final cmdName in namespace.commands.keys) {
      commands.add('$namespaceId.$cmdName');
    }

    // 递归添加子命名空间中的命令
    for (final entry in namespace.subNamespaces.entries) {
      commands.addAll(
        _getAllCommandsInNamespace('$namespaceId.${entry.key}', entry.value),
      );
    }

    return commands;
  }

  /// 获取所有可用命令 ID（平铺列表）
  List<String> get allCommandIds {
    final ids = <String>[];
    for (final ns in namespaces.values) {
      ids.addAll(ns.commands);
    }
    return ids;
  }

  /// 获取命令的所属命名空间 ID（顶层）
  String? getTopNamespaceForCommand(String commandId) {
    final parts = commandId.split('.');
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return null;
  }

  /// 获取命令的显示名称
  String getCommandLabel(String commandId) {
    final parts = commandId.split('.');
    return parts.isNotEmpty ? parts.last : commandId;
  }

  /// 按命名空间分组命令 ID
  Map<String, List<String>> groupCommandsByNamespace(
    Iterable<String> commandIds,
  ) {
    final grouped = <String, List<String>>{};
    for (final id in commandIds) {
      final topNs = getTopNamespaceForCommand(id);
      if (topNs != null) {
        grouped.putIfAbsent(topNs, () => []).add(id);
      }
    }
    return grouped;
  }
}
