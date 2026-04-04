import 'dart:convert';

import '../cli_base.dart';
import '../../services/os_tool_registry.dart';
import '../../services/tool_config_service.dart';
import 'tools/network/network_namespace.dart';
import 'tools/web/web_namespace.dart';

/// [TOOLING 层] tools 命名空间 - Web 工具 + 工具配置管理
///
/// 子命名空间：
///   network — 网络工具分类（list/detail 查询）
///   web     — Web 搜索和抓取（search/fetch + 配置管理）
///
/// 注：OS 本地工具已独立为顶层 `os` 命名空间，使用 `shepaw os.*`
///
/// 使用分层路由，subcommand 格式为 `<sub-namespace>.<action>`：
///   shepaw tools network.list
///   shepaw tools network.detail --name web_search
///   shepaw tools web.search --query "..." [--limit n]
///   shepaw tools web.fetch --url "..." [--format ...] [--timeout n]
///   shepaw tools web.config                         — 查看所有 web 工具配置
///   shepaw tools web.search.config                  — 管理 web_search 配置
///   shepaw tools web.fetch.config                   — 管理 web_fetch 配置
///
/// 顶层扁平命令：
///   shepaw tools list   — 列出所有网络/web 工具
///
/// 工具配置命令（动态路由，拦截 `{tool_name}.config` 格式）：
///   shepaw tools web_search.config                    — 查看配置
///   shepaw tools web_search.config --action set-key   — 设置 API Key
///   shepaw tools web_search.config --action delete-key — 删除 API Key
///   shepaw tools config                               — 列出所有工具配置汇总
class ToolsNamespace extends CliNamespace {
  static final instance = ToolsNamespace._();
  ToolsNamespace._();

  @override
  String get namespace => 'tools';

  @override
  String get description => 'Network and web tools — search, fetch, config management';

  /// 顶层扁平命令：跨分类汇总列表 + 配置汇总
  @override
  Map<String, CliCommand> get commands => {
        'list': _ToolsAllListCommand(),
        'config': _ToolsConfigListCommand(),
      };

  /// 分层 sub-namespace
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'network': NetworkSubNamespace.instance,
        'web': WebSubNamespace.instance,
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List all network/web tools',
          'config': 'List all tool configuration summaries',
          'network.list': 'List network tools (query only)',
          'network.detail': 'Full docs for a network tool (--name <tool_name>)',
          'note': 'OS tools: use top-level "shepaw os.*" namespace instead',
          'web.search': 'Search the web (--query <q> [--limit n])',
          'web.fetch': 'Fetch URL content (--url <url> [--format text|markdown|html] [--timeout n])',
          'web.config': 'List configuration for all web tools',
          'web.search.config': 'Manage web_search config (API key, params, enable/disable)',
          'web.fetch.config': 'Manage web_fetch config (params, enable/disable)',
          '<tool_name>.config': 'Manage config for a specific tool',
        },
        'tool_config_actions': {
          '(default/get)': 'Show current config for the tool',
          'set-key': 'Set API key (pass --value <key>, omit for prompt)',
          'delete-key': 'Remove stored API key',
          'set-param': 'Set a parameter override (--key <k> --value <v>)',
          'delete-param': 'Clear all parameter overrides',
          'set-note': 'Set config note (--value <text>)',
          'delete': 'Delete all config for the tool',
          'enable': 'Enable the tool globally',
          'disable': 'Disable the tool globally',
        },
        'examples': [
          'shepaw tools list',
          'shepaw tools config',
          'shepaw tools network.list',
          '# OS tools are now at top-level: shepaw os.*',
          'shepaw tools network.detail --name web_search',
          'shepaw tools web.search --query "Flutter state management"',
          'shepaw tools web.search --query "Dart 3 records" --limit 5',
          'shepaw tools web.fetch --url https://dart.dev',
          'shepaw tools web.fetch --url https://example.com --format text --timeout 60',
          'shepaw tools web.config',
          'shepaw tools web.search.config',
          'shepaw tools web.search.config --action set-key --value sk-xxx',
          'shepaw tools web.search.config --action delete-key',
          'shepaw tools web.search.config --action set-param --key timeout --value 60',
          'shepaw tools web.search.config --action delete-param',
          'shepaw tools web.search.config --action set-note --value "Primary search key"',
          'shepaw tools web.search.config --action delete',
          'shepaw tools web.search.config --action disable',
          'shepaw tools web.search.config --action enable',
        ],
      };

  // ── 动态路由：拦截 {tool_name}.config ───────────────────────────────────

  @override
  Future<Map<String, dynamic>> execute(
      String subcommand, Map<String, String> flags) async {
    // 拦截 <tool_name>.config 格式
    if (subcommand.endsWith('.config') && subcommand.contains('.')) {
      final toolName = subcommand.substring(0, subcommand.length - '.config'.length);
      return _handleToolConfig(toolName, flags);
    }

    // 其他路由照常处理
    return super.execute(subcommand, flags);
  }

  /// 处理工具配置命令
  Future<Map<String, dynamic>> _handleToolConfig(
      String toolName, Map<String, String> flags) async {
    // 验证工具是否存在（支持 name 或 cliPath）
    final registry = OsToolRegistry.instance;
    final resolvedName = registry.resolveToolName(toolName);
    final tool = registry.tools
        .where((t) => t.name == resolvedName)
        .firstOrNull;
    if (tool == null) {
      return {
        'error': 'Unknown tool: $toolName',
        'hint': 'Run "shepaw tools list" to see available tools',
      };
    }

    // --help 处理
    if (flags.containsKey('help') || flags.containsKey('h')) {
      return _toolConfigHelp(toolName);
    }

    final action = flags['action'] ?? 'get';
    final service = ToolConfigService.instance;

    switch (action) {
      case 'get':
        return _actionGet(toolName, service);

      case 'set-key':
        final value = flags['value'];
        if (value == null || value.isEmpty) {
          return {
            'error': 'Missing --value flag for API key',
            'usage':
                'shepaw tools $toolName.config --action set-key --value <api_key>',
            'security_note':
                'Tip: avoid passing secrets in shell args — they appear in history. '
                'Consider piping: echo \$MY_KEY | ... (future feature)',
          };
        }
        return _actionSetKey(toolName, value, service);

      case 'delete-key':
        return _actionDeleteKey(toolName, service);

      case 'set-param':
        final key = flags['key'];
        final value = flags['value'];
        if (key == null || key.isEmpty) {
          return {
            'error': 'Missing --key flag',
            'usage':
                'shepaw tools $toolName.config --action set-param --key <param_name> --value <param_value>',
          };
        }
        return _actionSetParam(toolName, key, value, service);

      case 'delete-param':
        return _actionDeleteParam(toolName, service);

      case 'set-note':
        final value = flags['value'] ?? '';
        return _actionSetNote(toolName, value, service);

      case 'delete':
        return _actionDelete(toolName, service);

      case 'enable':
        return _actionSetEnabled(toolName, true, service);

      case 'disable':
        return _actionSetEnabled(toolName, false, service);

      default:
        return {
          'error': 'Unknown action: $action',
          'available_actions': [
            'get', 'set-key', 'delete-key', 'set-param',
            'delete-param', 'set-note', 'delete', 'enable', 'disable',
          ],
          'usage':
              'shepaw tools $toolName.config --action <action> [--key k] [--value v]',
        };
    }
  }

  // ── 各 action 实现 ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _actionGet(
      String toolName, ToolConfigService service) async {
    final config = await service.getToolConfig(toolName);
    if (config == null) {
      return {
        'tool_name': toolName,
        'configured': false,
        'message': 'No configuration found. Use --action set-key or --action set-param to configure.',
      };
    }
    return {
      'tool_name': config.toolName,
      'configured': true,
      'enabled': config.enabled,
      'has_api_key': config.hasApiKey,
      // API Key 本身不输出，仅显示遮盖
      'api_key_status': config.hasApiKey ? '*** (configured)' : 'not set',
      'parameter_overrides': config.parameterOverrides,
      'note': config.note,
      'updated_at': DateTime.fromMillisecondsSinceEpoch(config.updatedAt)
          .toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _actionSetKey(
      String toolName, String apiKey, ToolConfigService service) async {
    await service.setToolApiKey(toolName, apiKey);
    return {
      'tool_name': toolName,
      'action': 'set-key',
      'success': true,
      'message': 'API key stored securely.',
    };
  }

  Future<Map<String, dynamic>> _actionDeleteKey(
      String toolName, ToolConfigService service) async {
    final config = await service.getToolConfig(toolName);
    if (config == null || !config.hasApiKey) {
      return {
        'tool_name': toolName,
        'action': 'delete-key',
        'success': false,
        'message': 'No API key configured for $toolName.',
      };
    }
    await service.deleteToolApiKey(toolName);
    return {
      'tool_name': toolName,
      'action': 'delete-key',
      'success': true,
      'message': 'API key removed.',
    };
  }

  Future<Map<String, dynamic>> _actionSetParam(
      String toolName,
      String paramKey,
      String? paramValue,
      ToolConfigService service) async {
    final config = await service.getToolConfig(toolName);
    final existing = Map<String, dynamic>.from(config?.parameterOverrides ?? {});
    if (paramValue == null) {
      existing.remove(paramKey);
    } else {
      // 尝试解析为数字/布尔，否则保留字符串
      existing[paramKey] = _parseParamValue(paramValue);
    }
    await service.saveToolConfig(
      toolName,
      parameterOverrides: existing.isEmpty ? null : existing,
      clearParameterOverrides: existing.isEmpty,
    );
    return {
      'tool_name': toolName,
      'action': 'set-param',
      'success': true,
      'parameter_overrides': existing.isEmpty ? null : existing,
      'message': paramValue == null
          ? 'Parameter "$paramKey" removed.'
          : 'Parameter "$paramKey" set to ${_parseParamValue(paramValue)}.',
    };
  }

  Future<Map<String, dynamic>> _actionDeleteParam(
      String toolName, ToolConfigService service) async {
    await service.saveToolConfig(
      toolName,
      clearParameterOverrides: true,
    );
    return {
      'tool_name': toolName,
      'action': 'delete-param',
      'success': true,
      'message': 'All parameter overrides cleared.',
    };
  }

  Future<Map<String, dynamic>> _actionSetNote(
      String toolName, String note, ToolConfigService service) async {
    if (note.isEmpty) {
      await service.saveToolConfig(toolName, clearNote: true);
      return {
        'tool_name': toolName,
        'action': 'set-note',
        'success': true,
        'message': 'Note cleared.',
      };
    }
    await service.saveToolConfig(toolName, note: note);
    return {
      'tool_name': toolName,
      'action': 'set-note',
      'success': true,
      'note': note,
    };
  }

  Future<Map<String, dynamic>> _actionDelete(
      String toolName, ToolConfigService service) async {
    await service.deleteToolConfig(toolName);
    return {
      'tool_name': toolName,
      'action': 'delete',
      'success': true,
      'message': 'All configuration (including API key) deleted for $toolName.',
    };
  }

  Future<Map<String, dynamic>> _actionSetEnabled(
      String toolName, bool enabled, ToolConfigService service) async {
    await service.saveToolConfig(toolName, enabled: enabled);
    return {
      'tool_name': toolName,
      'action': enabled ? 'enable' : 'disable',
      'success': true,
      'enabled': enabled,
    };
  }

  // ── 工具参数值解析 ────────────────────────────────────────────────────────

  dynamic _parseParamValue(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final intVal = int.tryParse(raw);
    if (intVal != null) return intVal;
    final doubleVal = double.tryParse(raw);
    if (doubleVal != null) return doubleVal;
    // 尝试解析为 JSON
    try {
      return jsonDecode(raw);
    } catch (_) {}
    return raw;
  }

  // ── 帮助信息 ──────────────────────────────────────────────────────────────

  Map<String, dynamic> _toolConfigHelp(String toolName) => {
        'command': '$toolName.config',
        'description': 'Manage configuration for tool: $toolName',
        'usage': 'shepaw tools $toolName.config [--action <action>] [--key k] [--value v]',
        'actions': {
          'get (default)': 'Show current configuration',
          'set-key': 'Set API key (--value <api_key>)',
          'delete-key': 'Remove stored API key',
          'set-param': 'Set parameter override (--key <param> --value <val>)',
          'delete-param': 'Clear all parameter overrides',
          'set-note': 'Set config note (--value <text>)',
          'delete': 'Delete all configuration for this tool',
          'enable': 'Enable this tool globally',
          'disable': 'Disable this tool globally',
        },
        'examples': [
          'shepaw tools $toolName.config',
          'shepaw tools $toolName.config --action set-key --value sk-xxx',
          'shepaw tools $toolName.config --action delete-key',
          'shepaw tools $toolName.config --action set-param --key timeout --value 60',
          'shepaw tools $toolName.config --action delete-param',
          'shepaw tools $toolName.config --action delete',
          'shepaw tools $toolName.config --action disable',
        ],
      };
}

// ── Top-level all-tools list ─────────────────────────────────────────────────

class _ToolsAllListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all network/web tools';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'usage': 'shepaw tools list',
        'note': 'For OS tools use: shepaw os list',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    // 只列 network 分类的工具（OS 工具已移至顶层 os 命名空间）
    final tools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            t.category == 'network')
        .toList();

    return {
      'platform': platform,
      'tools': tools.map((t) => {
        'name': t.name,
        'description': t.description,
        'category': t.category,
        'risk': t.defaultRiskLevel,
      }).toList(),
      'total_count': tools.length,
      'note': 'OS tools are at top-level namespace. Use: shepaw os list',
    };
  }
}

// ── Tool config list (summary across all tools) ───────────────────────────────

class _ToolsConfigListCommand extends CliCommand {
  @override
  String get name => 'config';

  @override
  String get description => 'List configuration summary for all tools';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {},
        'usage': 'shepaw tools config',
        'note': 'To manage a specific tool\'s config, use: shepaw tools <tool_name>.config',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final service = ToolConfigService.instance;
    final platform = registry.currentPlatform;

    // 只列 network 分类工具（OS 工具已移至顶层 os 命名空间）
    final networkTools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            t.category == 'network')
        .toList();

    final allConfigs = await service.getAllToolConfigs();
    final configMap = {
      for (final c in allConfigs) c.toolName: c,
    };

    final result = networkTools.map((t) {
      final config = configMap[t.name];
      return {
        'tool_name': t.name,
        'category': t.category,
        'configured': config != null,
        'enabled': config?.enabled ?? true,
        'has_api_key': config?.hasApiKey ?? false,
        'has_param_overrides': config?.parameterOverrides != null,
        'note': config?.note,
      };
    }).toList();

    final configuredCount = result.where((r) => r['configured'] == true).length;

    return {
      'platform': platform,
      'total_tools': networkTools.length,
      'configured_tools': configuredCount,
      'tools': result,
      'hint': 'Use "shepaw tools <tool_name>.config" to manage a tool\'s config',
      'note': 'For OS tool config use: shepaw tools <os_tool_name>.config',
    };
  }
}
