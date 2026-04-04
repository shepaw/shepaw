import 'dart:convert';

import '../../../../services/tool_config_service.dart';

/// 通用工具配置操作 Mixin
///
/// 供 WebSearchCommand / WebFetchCommand 等命令复用，
/// 使每个命令自己管理自身工具的配置（API Key、参数、启用/禁用等）。
///
/// 用法：
///   class WebSearchCommand extends CliCommand with WebToolConfigMixin { ... }
///
///   在命令的 execute() 中检测 subcommand 为 'config'，然后调用:
///     return handleConfig(toolName, shortName, flags);
mixin WebToolConfigMixin {
  // ── 入口 ──────────────────────────────────────────────────────────────────

  /// 处理配置子命令
  ///
  /// [toolName]  工具注册名，如 `web_search`
  /// [shortName] 命令短名，如 `search`（用于错误提示）
  /// [flags]     CLI 解析的键值对
  Future<Map<String, dynamic>> handleConfig(
    String toolName,
    String shortName,
    Map<String, String> flags,
  ) async {
    if (flags.containsKey('help') || flags.containsKey('h')) {
      return _configHelp(shortName, toolName);
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
                'shepaw tools web.$shortName.config --action set-key --value <api_key>',
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
                'shepaw tools web.$shortName.config --action set-param --key <param> --value <val>',
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
            'get',
            'set-key',
            'delete-key',
            'set-param',
            'delete-param',
            'set-note',
            'delete',
            'enable',
            'disable',
          ],
          'usage':
              'shepaw tools web.$shortName.config --action <action> [--key k] [--value v]',
        };
    }
  }

  // ── Action 实现 ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _actionGet(
      String toolName, ToolConfigService service) async {
    final config = await service.getToolConfig(toolName);
    if (config == null) {
      return {
        'tool_name': toolName,
        'configured': false,
        'message':
            'No configuration found. Use --action set-key or --action set-param to configure.',
      };
    }
    return {
      'tool_name': config.toolName,
      'configured': true,
      'enabled': config.enabled,
      'has_api_key': config.hasApiKey,
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
    ToolConfigService service,
  ) async {
    final config = await service.getToolConfig(toolName);
    final existing =
        Map<String, dynamic>.from(config?.parameterOverrides ?? {});
    if (paramValue == null) {
      existing.remove(paramKey);
    } else {
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
    await service.saveToolConfig(toolName, clearParameterOverrides: true);
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

  // ── 帮助信息 ────────────────────────────────────────────────────────────────

  Map<String, dynamic> _configHelp(String shortName, String toolName) => {
        'command': '$shortName.config',
        'description': 'Manage configuration for: $toolName',
        'usage':
            'shepaw tools web.$shortName.config [--action <action>] [--key k] [--value v]',
        'actions': {
          'get (default)': 'Show current configuration',
          'set-key': 'Set API key (--value <api_key>)',
          'delete-key': 'Remove stored API key',
          'set-param': 'Set parameter override (--key <param> --value <val>)',
          'delete-param': 'Clear all parameter overrides',
          'set-note': 'Set config note (--value <text>)',
          'delete': 'Delete all configuration',
          'enable': 'Enable this tool',
          'disable': 'Disable this tool',
        },
        'examples': [
          'shepaw tools web.$shortName.config',
          'shepaw tools web.$shortName.config --action set-key --value sk-xxx',
          'shepaw tools web.$shortName.config --action delete-key',
          'shepaw tools web.$shortName.config --action set-param --key timeout --value 60',
          'shepaw tools web.$shortName.config --action delete-param',
          'shepaw tools web.$shortName.config --action delete',
          'shepaw tools web.$shortName.config --action disable',
        ],
      };
}
