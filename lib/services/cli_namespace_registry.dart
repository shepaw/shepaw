import '../clis/shepaw/context/context_namespace.dart';
import '../clis/shepaw/chat/chat_namespace.dart';
import '../clis/shepaw/tools_namespace.dart';
import '../clis/shepaw/skills_namespace.dart';
import '../clis/shepaw/meta/meta_namespace.dart';
import '../clis/shepaw/help_namespace.dart';

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

/// CLI 命令注册表 - 列举所有可用的 CLI 命令
/// 并按命名空间组织，便于 agent 选择
/// 
/// 使用单例模式，与其他服务保持一致。
class CliNamespaceRegistry {
  CliNamespaceRegistry._();
  static final CliNamespaceRegistry instance = CliNamespaceRegistry._();

  /// 所有可用的顶层命名空间及其命令
  /// 
  /// 结构：{
  ///   'context': CliNamespaceInfo(
  ///     id: 'context',
  ///     label: 'Context',
  ///     description: "She's internal state — profile, memory, agents",
  ///     commands: ['context.profile.query', 'context.profile.update', ...]
  ///   ),
  ///   ...
  /// }
  late final Map<String, CliNamespaceInfo> _namespaces = _buildNamespaces();

  Map<String, CliNamespaceInfo> _buildNamespaces() {
    return {
      'context': CliNamespaceInfo(
        id: 'context',
        label: 'Context',
        description: "She's internal state — profile, memory, agents",
        commands: _getAllCommandsInNamespace(
          'context',
          ContextNamespace.instance,
        ),
      ),
      'chat': CliNamespaceInfo(
        id: 'chat',
        label: 'Chat',
        description: 'Channels and message history',
        commands: _getAllCommandsInNamespace(
          'chat',
          ChatNamespace.instance,
        ),
      ),
      'tools': CliNamespaceInfo(
        id: 'tools',
        label: 'Tools',
        description: 'Local OS tools and skills',
        commands: _getAllCommandsInNamespace(
          'tools',
          ToolsNamespace.instance,
        ),
      ),
      'skills': CliNamespaceInfo(
        id: 'skills',
        label: 'Skills',
        description: 'Loaded LLM skill modules',
        commands: _getAllCommandsInNamespace(
          'skills',
          SkillsNamespace.instance,
        ),
      ),
      'meta': CliNamespaceInfo(
        id: 'meta',
        label: 'Meta',
        description: 'System info and utilities',
        commands: _getAllCommandsInNamespace(
          'meta',
          MetaNamespace.instance,
        ),
      ),
      'help': CliNamespaceInfo(
        id: 'help',
        label: 'Help',
        description: 'CLI reference and examples',
        commands: _getAllCommandsInNamespace(
          'help',
          HelpNamespace.instance,
        ),
      ),
    };
  }

  /// 递归获取命名空间中的所有命令 ID
  /// 支持嵌套命名空间（如 context.profile.*)
  List<String> _getAllCommandsInNamespace(
    String namespaceId,
    dynamic namespace,
  ) {
    final commands = <String>[];

    // 添加该级别的直接命令
    if (namespace.commands is Map) {
      for (final cmdName in (namespace.commands as Map).keys) {
        commands.add('$namespaceId.$cmdName');
      }
    }

    // 递归添加子命名空间中的命令
    if (namespace.subNamespaces is Map) {
      for (final entry in (namespace.subNamespaces as Map).entries) {
        final subNsId = entry.key as String;
        final subNs = entry.value;
        final subCommands = _getAllCommandsInNamespace(
          '$namespaceId.$subNsId',
          subNs,
        );
        commands.addAll(subCommands);
      }
    }

    return commands;
  }

  /// 获取所有命名空间信息
  Map<String, CliNamespaceInfo> get namespaces => _namespaces;

  /// 获取所有可用命令 ID（平铺列表）
  List<String> get allCommandIds {
    final ids = <String>[];
    for (final ns in _namespaces.values) {
      ids.addAll(ns.commands);
    }
    return ids;
  }

  /// 验证命令 ID 是否存在
  bool isValidCommandId(String commandId) {
    return allCommandIds.contains(commandId);
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
