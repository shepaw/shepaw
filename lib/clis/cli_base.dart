import 'dart:convert';
import 'dart:io' show Platform;

import '../models/cli_config_field.dart';
import '../models/command_config_schema.dart';
import '../models/remote_agent.dart';
import '../services/tool_config_service.dart';
import '../services/cli_command_config_service.dart';

/// Minimal interface for sending messages as She.
/// Implemented by ChatService to avoid circular imports.
abstract class IPawChatSender {
  Future<void> sendAsSheTo({
    required RemoteAgent targetAgent,
    required String channelId,
    required String message,
  });
}

/// 单个叶子命令的抽象基类
abstract class CliCommand {
  /// 命令名（如 "fields", "query", "write"）
  String get name;

  /// 命令简短描述
  String get description;

  /// 命令的 icon（用于 UI 展示）
  /// 返回值可以是：
  /// - Emoji（如 '📁', '🔍'）
  /// - Icon 代码（如 'icons.folder', 'icons.search'）
  /// - null（使用默认 icon）
  /// 子类可覆盖；默认返回 null
  String? get icon => null;

  /// 用法示例（如 'shepaw context profile.query [--fields name,age,...]'）
  /// 子类可覆盖；默认返回空字符串
  String get usage => '';

  /// 支持的平台集合（如 {'macos', 'linux', 'windows'}, {'ios', 'android'}, 等）
  /// 默认值：所有平台 {'macos', 'linux', 'windows', 'android', 'ios'}
  /// 
  /// 用于在运行时过滤不支持当前平台的命令。
  /// 通过 Platform.isMacOS, Platform.isLinux 等检查当前平台。
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android', 'ios'};

  /// 命令的配置 Schema（可选）
  ///
  /// 声明此命令需要哪些可配置项（API Key、参数等）。
  /// - 返回非 null：该命令支持 `.config` 子命令和 `--config` flag，框架自动处理
  /// - 返回 null（默认）：该命令无需配置，`config` 路由不响应
  ///
  /// 示例：
  /// ```dart
  /// @override
  /// CommandConfigSchema? get configSchema => CommandConfigSchema(
  ///   toolName: 'brave_search',
  ///   displayName: 'Brave Search',
  ///   fields: [
  ///     CliConfigField(key: 'api_key', label: 'API Key',
  ///         type: CliConfigFieldType.secret, required: true,
  ///         description: 'Your Brave Search API key (BSA-...)'),
  ///   ],
  /// );
  /// ```
  CommandConfigSchema? get configSchema => null;

  /// 执行命令
  /// flags: 从 CLI 解析的键值对（如 {field: "name", value: "小明"}）
  Future<Map<String, dynamic>> execute(Map<String, String> flags);

  /// 检查命令是否可用（所有必填配置字段是否已完整配置）
  ///
  /// - 如果命令无 [configSchema]，返回 (true, null)（无需配置，总是可用）
  /// - 如果有必填字段（[CommandConfigSchema.requiredFields]），检查是否已填
  ///   - secret 类型字段 → 查 SecureStorage
  ///   - 其他必填字段 → 查 parameterOverrides
  ///
  /// 返回 `(isAvailable, reason)`：
  /// - `isAvailable == true` 时 reason 为 null
  /// - `isAvailable == false` 时 reason 说明第一个未满足的必填字段
  ///
  /// 子类可覆盖以实现自定义可用性检查（建议调用 `super.checkAvailability()`）。
  Future<(bool, String?)> checkAvailability() async {
    final schema = configSchema;
    if (schema == null) return (true, null);

    final requiredFields = schema.requiredFields;
    if (requiredFields.isEmpty) return (true, null);

    final service = ToolConfigService.instance;
    final toolName = schema.toolName;
    final config = await service.getToolConfig(toolName);

    // 统一检查必填项是否已配置。
    // 分支仅因存储后端不同：secret 类型存于 OS Keychain/Keystore（SecureStorage），
    // 其他类型存于 SQLite 的 parameterOverrides，两者均通过"是否有值"判断是否满足。
    for (final field in requiredFields) {
      if (field.type == CliConfigFieldType.secret) {
        final secret = await service.getToolSecret(toolName, field.key);
        if (secret == null || secret.isEmpty) {
          return (false, 'Missing required config: ${field.label} (${field.key})');
        }
      } else {
        final value = config?.parameterOverrides?[field.key];
        if (value == null || value.toString().isEmpty) {
          return (false, 'Missing required config: ${field.label} (${field.key})');
        }
      }
    }

    return (true, null);
  }

  /// 返回命令帮助信息
  ///
  /// 子类可覆盖以提供详细的 flags 文档（建议调用 `super.getHelp()` 合并）。
  /// 注意：此方法为同步，不含可用性检查。
  /// 框架在 getHelp 路由触发时会自动追加 available / reason_unavailable 字段，
  /// 子类无需手动处理。
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        if (usage.isNotEmpty) 'usage': usage,
        if (configSchema != null)
          'config_hint': 'This command has configurable settings. '
              'Use --config or .<cmd>.config to manage.',
      };

  /// 返回当前配置状态（只读）
  ///
  /// 若 [configSchema] 为 null，返回 'not configurable' 提示。
  /// 框架在收到 `--config` flag（无 `--action`）时自动调用此方法。
  Future<Map<String, dynamic>> getConfig() async {
    final schema = configSchema;
    if (schema == null) {
      return {'error': 'Command "$name" has no configurable settings.'};
    }
    return _configActionGet(schema.toolName, schema);
  }

  /// 处理 `.config` 子命令（由框架自动调用，子类无需覆盖）
  ///
  /// 支持 6 个 action，通过 `--action` flag 指定：
  ///   get（默认）、schema、set、delete、enable、disable
  ///
  /// `set` 通过 `--key` 指定字段名，`--value` 指定值：
  ///   - key 对应 schema 中 [CliConfigFieldType.secret] 类型 → 存入 SecureStorage
  ///   - 其他 key → 存入 parameterOverrides
  ///   - 省略 --value → 清除该字段
  ///
  /// 子类可覆盖此方法以添加自定义 action，
  /// 建议先处理自定义 action 再调用 `super.handleConfig(flags)`。
  Future<Map<String, dynamic>> handleConfig(Map<String, String> flags) async {
    final schema = configSchema;
    if (schema == null) {
      return {'error': 'Command "$name" has no configurable settings.'};
    }

    if (flags.containsKey('help') || flags.containsKey('h')) {
      return _configHelp(schema);
    }

    final action = flags['action'] ?? 'get';
    final toolName = schema.toolName;
    final service = ToolConfigService.instance;

    switch (action) {
      case 'get':
        return _configActionGet(toolName, schema);

      case 'schema':
        return {
          'tool_name': toolName,
          'schema': schema.toJson(),
        };

      case 'set':
        final key = flags['key'];
        if (key == null || key.isEmpty) {
          return {
            'error': 'Missing --key flag',
            'usage': _configUsage(schema),
            'example': '$usage --config --action set --key <secret_field> --value YOUR_KEY',
          };
        }
        return _configActionSet(toolName, key, flags['value'], schema, service);

      case 'delete':
        return _configActionDelete(toolName, service);

      case 'enable':
        return _configActionSetEnabled(toolName, true, service);

      case 'disable':
        return _configActionSetEnabled(toolName, false, service);

      default:
        return {
          'error': 'Unknown action: $action',
          'available_actions': ['get', 'schema', 'set', 'delete', 'enable', 'disable'],
          'usage': _configUsage(schema),
        };
    }
  }

  // ── config action 实现（内部）─────────────────────────────────────────────

  Future<Map<String, dynamic>> _configActionGet(
      String toolName, CommandConfigSchema schema) async {
    final service = ToolConfigService.instance;
    final config = await service.getToolConfig(toolName);

    // 构建每个必填字段的配置状态
    Future<Map<String, dynamic>> buildFieldStatus(CliConfigField field) async {
      final bool configured;
      if (field.type == CliConfigFieldType.secret) {
        final secret = await service.getToolSecret(toolName, field.key);
        configured = secret != null && secret.isNotEmpty;
      } else {
        final value = config?.parameterOverrides?[field.key];
        configured = value != null && value.toString().isNotEmpty;
      }
      return {
        'key': field.key,
        'label': field.label,
        'type': field.type.name,
        'configured': configured,
      };
    }

    final requiredFieldStatuses = await Future.wait(
      schema.requiredFields.map(buildFieldStatus),
    );

    if (config == null) {
      return {
        'tool_name': toolName,
        'display_name': schema.displayName,
        'configured': false,
        'required_fields': requiredFieldStatuses,
        'message': 'No configuration found.',
        'hint': 'Use --config --action set --key <field> --value <val> to configure.',
      };
    }
    return {
      'tool_name': config.toolName,
      'display_name': schema.displayName,
      'configured': true,
      'required_fields': requiredFieldStatuses,
      'parameter_overrides': config.parameterOverrides,
      'note': config.note,
      'updated_at':
          DateTime.fromMillisecondsSinceEpoch(config.updatedAt).toIso8601String(),
    };
  }

  /// 统一的 set action：根据 schema 字段类型自动路由到正确的存储
  ///   - [CliConfigFieldType.secret] → SecureStorage
  ///   - 其他字段 → parameterOverrides
  ///   - value 为 null → 清除该字段
  Future<Map<String, dynamic>> _configActionSet(
    String toolName,
    String key,
    String? value,
    CommandConfigSchema schema,
    ToolConfigService service,
  ) async {
    final field = schema.findField(key);
    if (field == null) {
      return {
        'error': 'Unknown field: $key',
        'available_fields': schema.fields.map((f) => f.key).toList(),
      };
    }

    // secret 类型 → SecureStorage
    if (field.type == CliConfigFieldType.secret) {
      final allSecretKeys = schema.secretFields.map((f) => f.key).toList();
      if (value == null || value.isEmpty) {
        await service.deleteToolSecret(toolName, key, allSecretKeys);
        return {
          'tool_name': toolName,
          'action': 'set',
          'key': key,
          'success': true,
          'message': 'Secret "$key" removed.',
        };
      }
      await service.setToolSecret(toolName, key, value);
      return {
        'tool_name': toolName,
        'action': 'set',
        'key': key,
        'success': true,
        'message': 'Secret "$key" stored securely.',
      };
    }

    // 其他字段 → parameterOverrides
    final config = await service.getToolConfig(toolName);
    final existing = Map<String, dynamic>.from(config?.parameterOverrides ?? {});
    if (value == null) {
      existing.remove(key);
    } else {
      existing[key] = _parseParamValue(value);
    }
    await service.saveToolConfig(
      toolName,
      parameterOverrides: existing.isEmpty ? null : existing,
      clearParameterOverrides: existing.isEmpty,
    );
    return {
      'tool_name': toolName,
      'action': 'set',
      'key': key,
      'success': true,
      'message': value == null
          ? 'Field "$key" cleared.'
          : 'Field "$key" set to ${_parseParamValue(value)}.',
    };
  }

  Future<Map<String, dynamic>> _configActionDelete(
      String toolName, ToolConfigService service) async {
    await service.deleteToolConfig(toolName);
    return {
      'tool_name': toolName,
      'action': 'delete',
      'success': true,
      'message': 'All configuration (including secrets) deleted for $toolName.',
    };
  }

  Future<Map<String, dynamic>> _configActionSetEnabled(
      String toolName, bool enabled, ToolConfigService service) async {
    final commandConfigService = CliCommandConfigService.instance;
    await commandConfigService.saveConfig(toolName, globalEnabled: enabled);
    return {
      'tool_name': toolName,
      'action': enabled ? 'enable' : 'disable',
      'success': true,
      'enabled': enabled,
    };
  }

  // ── 参数值解析 ──────────────────────────────────────────────────────────────

  dynamic _parseParamValue(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final intVal = int.tryParse(raw);
    if (intVal != null) return intVal;
    final doubleVal = double.tryParse(raw);
    if (doubleVal != null) return doubleVal;
    try {
      return jsonDecode(raw);
    } catch (_) {}
    return raw;
  }

  // ── config 帮助 & usage ────────────────────────────────────────────────────

  Map<String, dynamic> _configHelp(CommandConfigSchema schema) => {
        'command': '$name.config',
        'tool_name': schema.toolName,
        'display_name': schema.displayName,
        'description': schema.description ?? 'Manage configuration for: ${schema.toolName}',
        'usage': _configUsage(schema),
        'fields': schema.toJson()['fields'],
        'actions': {
          'get (default)': 'Show current configuration',
          'schema': 'Show the full configuration schema with all fields',
          'set': 'Set a field value (--key <field> --value <val>); omit --value to clear the field',
          'delete': 'Delete all configuration for this tool (including API key)',
          'enable': 'Enable this tool globally',
          'disable': 'Disable this tool globally',
        },
        'examples': [
          '$usage --config',
          '$usage --config --action schema',
          '$usage --config --action set --key api_key --value YOUR_KEY',
          '$usage --config --action set --key timeout --value 60',
          '$usage --config --action set --key timeout   (clears the field)',
          '$usage --config --action delete',
          '$usage --config --action disable',
        ],
      };

  String _configUsage(CommandConfigSchema schema) =>
      '$usage --config [--action <action>] [--key k] [--value v]';

  /// i18n 支持预留（当前返回 key，便于后续扩展）
  String getMessage(String key, {Map<String, String>? args}) => key;
}

/// 命名空间的抽象基类，管理一组子命令
///
/// 支持两种模式：
///
/// 1. **扁平模式**（单层命名空间）
///    shepaw <namespace> <subcommand> [flags]
///    — 实现 [commands]，[subNamespaces] 返回空 map（默认）
///
/// 2. **分层模式**（嵌套 sub-namespace）
///    shepaw <namespace> <sub-namespace>.<action> [flags]
///    — 实现 [subNamespaces]，[commands] 返回空 map（默认）
///    — subcommand 格式：`profile.query`、`memory.write`
///
/// 分层模式示例：
/// ```
/// shepaw context profile.query
/// shepaw context memory.write --key soul --value "..."
/// shepaw context agents.list --status online
/// ```
///
/// config 内置支持（与 help 对称）：
/// - `--config` flag：返回命令当前配置状态（等价于 `--config --action get`）
/// - `<cmd>.config` 子命令：进入配置管理（支持所有 action）
/// - 仅当命令声明了 [CliCommand.configSchema] 时生效
abstract class CliNamespace {
  /// 命名空间名（如 "profile", "memory", "context"）
  String get namespace;

  /// 命名空间描述
  String get description;

  /// 命名空间的 icon（用于 UI 展示）
  /// 返回值可以是：
  /// - Emoji（如 '🧠', '💬'）
  /// - Icon 代码（如 'icons.brain', 'icons.chat'）
  /// - null（使用默认 icon）
  /// 子类可覆盖；默认返回 null
  String? get icon => null;

  /// 用法示例（如 'shepaw context <sub-namespace>.<action> [flags]'）
  /// 子类可覆盖
  String get usage => '';

  /// 支持的平台集合（如 {'macos', 'linux', 'windows'}, {'ios', 'android'}, 等）
  /// 默认值：所有平台 {'macos', 'linux', 'windows', 'android', 'ios'}
  ///
  /// 用于在运行时过滤不支持当前平台的命名空间。
  /// 注意：子命名空间（subNamespaces）和命令（commands）也有各自的平台过滤，
  /// 此处声明的是该命名空间整体是否可用于当前平台。
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android', 'ios'};

  /// 所有扁平子命令（单层模式）；分层模式返回空 map
  ///
  /// 注册规范：
  /// - key 直接取实例的 [CliCommand.name]，不要硬编码字符串
  /// - 注册前用 [currentPlatformName] 判断平台，不支持则不加入
  ///
  /// 示例：
  /// ```dart
  /// @override
  /// Map<String, CliCommand> get commands => {
  ///   for (final cmd in [_FooCommand(), _BarCommand()])
  ///     if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
  /// };
  /// ```
  Map<String, CliCommand> get commands => {};

  /// 嵌套的 sub-namespace（分层模式）；扁平模式返回空 map
  ///
  /// 注册规范：
  /// - key 直接取实例的 [CliNamespace.namespace]，不要硬编码字符串
  /// - 注册前用 [currentPlatformName] 判断平台，不支持则不加入
  ///
  /// 示例：
  /// ```dart
  /// @override
  /// Map<String, CliNamespace> get subNamespaces => {
  ///   for (final ns in [FooNamespace.instance, BarNamespace.instance])
  ///     if (ns.supportedPlatforms.contains(currentPlatformName)) ns.namespace: ns,
  /// };
  /// ```
  Map<String, CliNamespace> get subNamespaces => {};

  /// 执行子命令
  ///
  /// 路由优先级（从高到低）：
  /// 1. 已知 sub-namespace 前缀 → 交给对应 CliNamespace 处理（仅当支持当前平台）
  /// 2. 空字符串 / "help" → 返回当前命名空间帮助
  /// 3. 含 "." 的字符串 → 分层路由（sub-namespace.action）
  ///    - 特例：`<cmd>.config` → 路由到对应命令的 handleConfig()
  /// 4. 其他 → 扁平路由查 commands（仅当支持当前平台）
  ///    - `--help` flag → 返回命令帮助
  ///    - `--config` flag → 返回命令配置（需声明 configSchema）
  ///    - 否则 → 执行命令
  Future<Map<String, dynamic>> execute(
      String subcommand, Map<String, String> flags) async {
    // ── 1. 已知 sub-namespace 前缀：优先交给分层路由，避免 .config 提前消费 ──
    final firstSegment = subcommand.contains('.')
        ? subcommand.split('.').first
        : (subNamespaces.containsKey(subcommand) ? subcommand : null);
    if (firstSegment != null && subNamespaces.containsKey(firstSegment)) {
      // 直接访问 sub-namespace 本身（无 action）→ 返回该 sub-namespace 帮助（含可用性）
      if (subcommand == firstSegment) {
        return subNamespaces[firstSegment]!.getHelpAsync();
      }
      final action = subcommand.substring(firstSegment.length + 1);
      return subNamespaces[firstSegment]!.execute(action, flags);
    }

    // ── 2. help ───────────────────────────────────────────────────────────────
    if (subcommand.isEmpty || subcommand == 'help') {
      return getHelpAsync();
    }

    // ── 3. 含 "." → 分层路由 ──────────────────────────────────────────────────
    if (subcommand.contains('.')) {
      final dot = subcommand.indexOf('.');
      final cmdName = subcommand.substring(0, dot);
      final rest = subcommand.substring(dot + 1);

      // 特例：<cmd>.config → 路由到命令的 handleConfig()
      if (rest == 'config') {
        final cmd = commands[cmdName];
        if (cmd != null) {
          return cmd.handleConfig(flags);
        }
      }

      // 其他分层路由：交给 sub-namespace
      final ns = subNamespaces[cmdName];
      if (ns != null) {
        return ns.execute(rest, flags);
      }

      return {
        'error': 'Unknown subcommand: $subcommand',
        'usage': 'shepaw $namespace <sub-namespace>.<action> [flags]',
        'available_sub_namespaces': subNamespaces.keys.toList(),
      };
    }

    // ── 4. 扁平路由：直接查 commands ──────────────────────────────────────────
    final cmd = commands[subcommand];
    if (cmd == null) {
      if (flags.containsKey('help') || flags.containsKey('h')) {
        return getHelpAsync();
      }
      return _unknownSubcommand(subcommand);
    }

    // 找到命令 → 检查特殊 flags
    if (flags.containsKey('help') || flags.containsKey('h')) {
      return _cmdHelpWithAvailability(cmd);
    }

    // --config flag：进入配置管理（与 --help 对称）
    if (flags.containsKey('config')) {
      return cmd.handleConfig(flags);
    }

    return cmd.execute(flags);
  }

  /// 生成帮助信息（异步版本，含命令可用性检查）
  ///
  /// 对所有 [commands] 调用 [CliCommand.checkAvailability]，
  /// 在每个命令条目中追加 `available` 字段（true/false）；
  /// 若不可用则同时追加 `reason_unavailable` 字段。
  ///
  /// 子命名空间（[subNamespaces]）不做异步可用性检查，仅列出 description。
  ///
  /// 子类可覆盖以添加额外字段（建议调用 `super.getHelpAsync()` 合并）。
  Future<Map<String, dynamic>> getHelpAsync() async {
    final result = <String, dynamic>{
      'namespace': namespace,
      'description': description,
    };

    if (usage.isNotEmpty) {
      result['usage'] = usage;
    }

    // 自动聚合 sub-namespaces
    if (subNamespaces.isNotEmpty) {
      result['sub_namespaces'] = {
        for (final entry in subNamespaces.entries)
          entry.key: entry.value.description,
      };
    }

    // 自动聚合 commands（含可用性检查）
    if (commands.isNotEmpty) {
      final commandMap = <String, dynamic>{};
      for (final entry in commands.entries) {
        final cmd = entry.value;
        final (isAvailable, reason) = await cmd.checkAvailability();
        final cmdInfo = <String, dynamic>{
          'description': cmd.description,
          'available': isAvailable,
          if (!isAvailable && reason != null) 'reason_unavailable': reason,
        };
        commandMap[entry.key] = cmdInfo;
      }
      result['commands'] = commandMap;
    }

    // 自动生成 examples
    final examples = <String>[];
    for (final cmd in commands.values) {
      if (cmd.usage.isNotEmpty) examples.add(cmd.usage);
    }
    for (final ns in subNamespaces.values) {
      if (ns.usage.isNotEmpty) examples.add(ns.usage);
    }
    if (examples.isNotEmpty) {
      result['examples'] = examples;
    }

    return result;
  }

  /// 生成帮助信息（同步版本，不含可用性检查）
  ///
  /// 仅在需要同步返回时使用（如内部路由、旧版兼容）。
  /// 绝大多数场景应优先使用 [getHelpAsync]，以便 Agent 获得完整的可用性信息。
  ///
  /// 子类可覆盖以添加额外字段（建议调用 `super.getHelp()` 合并）。
  Map<String, dynamic> getHelp() {
    final result = <String, dynamic>{
      'namespace': namespace,
      'description': description,
    };

    if (usage.isNotEmpty) {
      result['usage'] = usage;
    }

    // 自动聚合 sub-namespaces
    if (subNamespaces.isNotEmpty) {
      result['sub_namespaces'] = {
        for (final entry in subNamespaces.entries)
          entry.key: entry.value.description,
      };
    }

    // 自动聚合 commands
    if (commands.isNotEmpty) {
      result['commands'] = {
        for (final entry in commands.entries)
          entry.key: entry.value.description,
      };
    }

    // 自动生成 examples
    final examples = <String>[];
    for (final cmd in commands.values) {
      if (cmd.usage.isNotEmpty) examples.add(cmd.usage);
    }
    for (final ns in subNamespaces.values) {
      if (ns.usage.isNotEmpty) examples.add(ns.usage);
    }
    if (examples.isNotEmpty) {
      result['examples'] = examples;
    }

    return result;
  }

  /// 单个命令的 help（含可用性检查）
  ///
  /// 取 [cmd.getHelp()] 的同步结果，再异步追加 `available` / `reason_unavailable` 字段。
  Future<Map<String, dynamic>> _cmdHelpWithAvailability(CliCommand cmd) async {
    final result = Map<String, dynamic>.from(cmd.getHelp());
    final (isAvailable, reason) = await cmd.checkAvailability();
    result['available'] = isAvailable;
    if (!isAvailable && reason != null) {
      result['reason_unavailable'] = reason;
      result['config_action'] =
          'Use: ${cmd.usage.isNotEmpty ? cmd.usage : 'shepaw $namespace ${cmd.name}'} --config --action set --key <field> --value <value>';
    }
    return result;
  }

  /// 未知子命令错误
  Map<String, dynamic> _unknownSubcommand(String sub) {
    if (subNamespaces.isNotEmpty) {
      return {
        'error': 'Unknown subcommand: $sub',
        'usage': 'shepaw $namespace <sub-namespace>.<action> [flags]',
        'available_sub_namespaces': subNamespaces.keys.toList(),
      };
    }
    return {
      'error': 'Unknown subcommand: $sub',
      'usage': 'shepaw $namespace <${commands.keys.join("|")}>',
      'available_subcommands': commands.keys.toList(),
    };
  }
}

// ── 全局平台工具 ────────────────────────────────────────────────────────────────

/// 返回当前运行平台的名称（统一格式，与 supportedPlatforms 中的值一致）
///
/// 返回值：'macos', 'linux', 'windows', 'android', 'ios' 之一
String get currentPlatformName {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'unknown';
}
