import 'dart:convert';
import '../cli_base.dart';
import 'context/context_namespace.dart';
import '../../services/she_service.dart';
import 'chat/chat_agent_scope.dart';
import 'chat/chat_namespace.dart';
import 'workflow/workflow_namespace.dart';
import 'skills_namespace.dart';
import 'tools/tools_namespace.dart';
import 'os/os_cli_namespace.dart';
import 'meta/meta_namespace.dart';
import 'help_namespace.dart';
import 'external_cli_namespace.dart';
import 'store/store_namespace.dart';
import 'instructions/instructions_namespace.dart';
import 'vision/vision_namespace.dart';
import 'models/models_namespace.dart';
import 'peer/peer_namespace.dart';
import 'events/events_namespace.dart';
import '../../services/logger_service.dart';
import '../../services/cli_command_config_service.dart';
import '../../services/cli_tool_registry.dart';
import '../cli_command_allowlist.dart';

/// ShepawCLI — She 专属的内嵌 CLI，替代 PawToolRegistry。
///
/// CLI 风格：
///   shepaw <namespace> [subcommand] [--flag value ...]
///
/// 命名空间按功能职责分为 4 个层级：
///
/// ─── 🧠 CONTEXT 层（She 的内部状态）─────────────────────────
///   context   档案 / 记忆 / AI 助手（profile.* / memory.* / agents.*）
///
/// ─── 💬 COMMUNICATION 层（实时对话和通信）───────────────────
///   chat      对话频道与消息（channels / messages / message.get / group.*）
///             group.create / add / kick / rename / send — 群管理（变更需管理员）
///
/// ─── 🔧 TOOLING 层（系统工具和功能能力）────────────────────
///   tools     系统工具（os.* / network.* / web.*）
///             web.search  Web 搜索（--query / --limit）
///             web.fetch   网页抓取（--url / --format / --timeout）
///             web.config  Web 工具配置管理
///   skills    已加载的 LLM 技能库（user-imported skills）
///   os        直接操作系统工具（shell/file/app/clipboard/process/macos）
///   models    AI 模型配置（list / providers / add / update / remove / agent-main）
///             — 查服务商预设、增删改模型、指派给 Agent 当主模型
///
/// ─── ℹ️ META 层（系统元信息和诊断）─────────────────────────
///   meta      系统信息、时间（system.* / datetime）
///   help      顶层帮助（顶级命令，动态聚合所有命名空间）
///
/// ─── 🔌 EXTERNAL 层（外部插拔式 CLI 工具）──────────────────
///   <namespace> 从 ~/shepaw/cli-tools/ 动态加载的外部工具
///
/// 详细架构文档见 NAMESPACE_ARCHITECTURE.md
class ShepawCLI {
  static final ShepawCLI instance = ShepawCLI._();
  ShepawCLI._();

  static const String toolName = 'shepaw';

  // ── 命名空间注册表 ───────────────────────────────────────────────────────────

  final Map<String, CliNamespace> _namespaces = {
    // ── 🧠 CONTEXT 层 - She 的内部状态 ──────────────────────────────────────────
    'context': ContextNamespace.instance,

    // ── 💬 COMMUNICATION 层 - 实时对话和通信 ────────────────────────────────────
    'chat': ChatNamespace.instance,

    // ── 🔧 TOOLING 层 - 系统工具和功能能力 ──────────────────────────────────────
    'tools': ToolsNamespace.instance,
    'skills': SkillsNamespace.instance,
    'os': OsCliNamespace.instance,
    'workflow': WorkflowNamespace.instance,
    // 存储空间产物读写（docs/storage_space_plan.md §6.3）
    'store': StoreNamespace.instance,
    // 可复用的任务指令集（save/list/get/update/delete/run）
    'instructions': InstructionsNamespace.instance,
    // 设备端人脸识别（参考相册 + 结构化视觉档案）
    'vision': VisionNamespace.instance,
    // AI 模型定义与配置（provider 预设 / 增删改 / 指派给 Agent 主模型）
    'models': ModelsNamespace.instance,
    // 设备配对（粘贴 shepaw://peer 链接 / 查询已配对设备）
    'peer': PeerNamespace.instance,
    // Agent 事件总线（wait / inbox / ack / types）
    'events': EventsNamespace.instance,

    // ── ℹ️ META 层 - 系统元信息和诊断 ───────────────────────────────────────────
    'meta': MetaNamespace.instance,
    'help': HelpNamespace.instance,
  };

  /// 从 [CliToolRegistry] 重新加载外部 CLI 工具到命名空间注册表。
  ///
  /// 在以下时机调用：
  /// - app 启动 CliToolRegistry.initialize() 后
  /// - 工具 install / uninstall / rescan 后
  void reloadExternalTools() {
    // 移除所有旧的外部工具命名空间
    _namespaces.removeWhere((_, v) => v is ExternalCliNamespace);

    // 添加当前已加载的外部工具
    for (final tool in CliToolRegistry.instance.tools) {
      if (!_namespaces.containsKey(tool.namespace)) {
        _namespaces[tool.namespace] = ExternalCliNamespace(tool);
      }
    }

    LoggerService().info(
      'Reloaded external CLI tools: '
      '${CliToolRegistry.instance.tools.map((t) => t.namespace).join(", ")}',
      tag: 'Paw',
    );
  }

  // ── LLM Tool Definitions ────────────────────────────────────────────────────

  bool isPawTool(String name) => name == toolName;

  Map<String, dynamic> openAITool({
    Set<String> enabledCliCommands = const {},
    Set<String>? extraAllowlist,
  }) =>
      {
        'type': 'function',
        'function': {
          'name': toolName,
          'description': _buildToolDescription(
            enabledCliCommands: enabledCliCommands,
            extraAllowlist: extraAllowlist,
          ),
          'parameters': _parameterSchema(
            enabledCliCommands: enabledCliCommands,
            extraAllowlist: extraAllowlist,
          ),
        },
      };

  Map<String, dynamic> claudeTool({
    Set<String> enabledCliCommands = const {},
    Set<String>? extraAllowlist,
  }) =>
      {
        'name': toolName,
        'description': _buildToolDescription(
          enabledCliCommands: enabledCliCommands,
          extraAllowlist: extraAllowlist,
        ),
        'input_schema': _parameterSchema(
          enabledCliCommands: enabledCliCommands,
          extraAllowlist: extraAllowlist,
        ),
      };

  /// 内置 CLI 的基础描述
  static const String _builtinToolDescription =
      'ShePaw built-in CLI. Use "shepaw help" to see all namespaces. '
      'Use "shepaw <namespace>" to see sub-commands. '
      'Use dot notation for nested commands (e.g. "shepaw context profile.query"). '
      'Add flags={"help":""} for detailed usage. '
      'IMPORTANT: chat history images are metadata-only — to read/analyze a past image, '
      'call namespace=chat subcommand=message.get with flags id=<message_id> analyze=<question>. '
      'Face/person recognition runs on-device: namespace=vision subcommand=album.enroll '
      '(flags person=, image=|message_id=) to register a person, recognize (flags image=|message_id=) '
      'to identify faces, album.list / profile.build / profile.get to manage profiles. '
      'Reusable tasks: when the user asks to save or generate an instruction from a task, '
      'call namespace=instructions subcommand=save (flags name=, content=, desc=) — it records '
      'you as the owning agent, and instructions run later auto-routes execution back to you. '
      'Use instructions list / get / update / delete / run to manage and execute the instruction set. '
      'Model configuration: when the user asks to configure AI models — e.g. a provider like '
      'DeepSeek just released a model and they want it set up, or they want to switch which '
      'model an agent chats with — call namespace=models (subcommands: list / providers / '
      'add / update / remove / agent-main; pass flags {"help": ""} for usage). '
      'Start with "shepaw models list"; verify brand-new model ids from the provider '
      'docs via web search, then add with namespace=models subcommand=add. Confirm '
      'changes with the user; never print API keys (outputs expose only has_api_key). '
      'Device pairing (shepaw://peer): Initiator — peer pair --link <URL> (optional '
      'events wait --correlation <id> --type peer.pairing.completed --timeout 30). '
      'Responder — peer offer (returns correlation_id + qr_link); She is auto-notified '
      'via active subscription — then peer accept (do NOT long-block events wait). '
      'Events: namespace=events — wait/inbox/ack/types/subscribe/list/emit/providers. '
      'RPC uses --correlation; human-speed flows use active subscription wake. '
      'shepaw://pair?... is agent enrollment — not peer pair.';

  /// 动态生成工具描述（包含外部工具信息）
  String _buildToolDescription({
    Set<String> enabledCliCommands = const {},
    Set<String>? extraAllowlist,
  }) {
    final suffix = CliToolRegistry.instance.toolDescriptionSuffix();
    final restriction = cliSchemaRestrictionNote(
      enabledCliCommands: enabledCliCommands,
      extraAllowlist: extraAllowlist,
    );
    final buf = StringBuffer(_builtinToolDescription);
    if (suffix.isNotEmpty) buf.write(suffix);
    if (restriction != null) {
      buf.write(' $restriction');
    }
    return buf.toString();
  }

  Map<String, dynamic> _parameterSchema({
    Set<String> enabledCliCommands = const {},
    Set<String>? extraAllowlist,
  }) {
    // 动态构建 subcommand 描述（包含外部工具）
    final extSubcmdDesc = CliToolRegistry.instance.externalSubcommandDescription();
    final subcommandDesc = StringBuffer(
      'Subcommand for the chosen namespace. '
      'Use dot notation for nested namespaces (e.g. "profile.query"). '
      'Omit to see available sub-commands for the namespace.',
    );
    if (extSubcmdDesc.isNotEmpty) {
      subcommandDesc.write('; $extSubcmdDesc');
    }

    return {
      'type': 'object',
      'properties': {
        'namespace': {
          'type': 'string',
          'enum': cliFilterNamespaces(
            _namespaces.keys,
            enabledCliCommands: enabledCliCommands,
            extraAllowlist: extraAllowlist,
          ),
          'description': 'Command namespace',
        },
        'subcommand': {
          'type': 'string',
          'description': subcommandDesc.toString(),
        },
        'flags': {
          'type': 'object',
          'description':
              'Command parameters as key-value pairs. '
              'Pass {"help": ""} to get help for any namespace, sub-namespace, or command. '
              'Common flags: name (tool/skill name), field (profile field), value (write value), '
              'fields (comma-separated list), key (memory key), id (agent ID), '
              'status (online|offline|all), channel (channel ID), category (tool category), '
              'limit (default 20), offset (default 0), message (chat content), '
              'keywords (comma-separated), type (memory/cognition type)',
          'additionalProperties': {'type': 'string'},
        },
      },
      'required': ['namespace'],
    };
  }

  // ── Command Execution ────────────────────────────────────────────────────────

  /// 执行 shepaw 命令，返回 JSON 字符串结果（供 LLM tool_result 使用）
  ///
  /// [args] 命令参数（namespace / subcommand / flags）
  /// [agentId] 当前执行命令的 Agent ID（默认为 She 的 ID）
  /// [isUiOperation] 是否来自 UI 操作（UI 操作跳过权限检查，默认 false）
  /// [channelId] 当前对话频道；flags 未带 channel 时作为 store 落点
  /// [runtimeOwnerId] 群聊时传入群 id，强制产物写入群 runtime
  /// [cliAllowlist] 非空时覆盖 Zone 内的允许列表（群成员 store/help 等）
  Future<String> execute(
    Map<String, dynamic> args, {
    String agentId = SheService.sheId,
    bool isUiOperation = false,
    String? channelId,
    String? runtimeOwnerId,
    Set<String>? cliAllowlist,
  }) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);

    LoggerService().info(
        'shepaw $namespace ${subcommand.isNotEmpty ? subcommand : ""} '
        '${_redactSensitiveFlags(flags)} [agentId=$agentId]',
        tag: 'Paw');

    try {
      final ns = _namespaces[namespace];
      if (ns == null) {
        return jsonEncode({
          'error': 'Unknown namespace: $namespace',
          'available': _namespaces.keys.toList(),
        });
      }

      if (namespace == 'help') {
        return jsonEncode(_buildHelpResult());
      }

      // 权限检查：全局启用 / She 专属
      // UI 操作（用户主动在界面点击执行）跳过权限检查
      final commandId = _buildCommandId(namespace, subcommand);
      if (!isUiOperation) {
        final denyReason = await CliCommandConfigService.instance
            .checkPermission(commandId, agentId: agentId);
        if (denyReason != null) {
          return jsonEncode({'error': denyReason, 'command': commandId});
        }
      }

      // 透传当前执行者的 agentId / channelId / 群 runtime owner（store write 等
      // 依赖）。并发成员工具调用必须在各自 Zone 内执行：读取点优先取 Zone 值，
      // 避免原先静态全局被并发覆盖的串号竞态。
      final flagChannel =
          (flags['channel_id'] ?? flags['channel'] ?? '').trim();
      final scopedChannel = flagChannel.isNotEmpty
          ? flagChannel
          : (channelId ?? '').trim();
      final scopedOwner = (runtimeOwnerId ?? '').trim();
      final scopedCorrelation = (flags['correlation'] ?? '').trim();
      final allowlist = cliAllowlist ?? ChatAgentScope.cliAllowlist;
      final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
        agentId: agentId,
        channelId: scopedChannel,
        runtimeOwnerId: scopedOwner,
        correlationId: scopedCorrelation.isNotEmpty
            ? scopedCorrelation
            : ChatAgentScope.correlationId,
        cliAllowlist: allowlist,
        body: () async {
          final scopedAllowlist = ChatAgentScope.cliAllowlist;
          if (scopedAllowlist != null &&
              !cliCommandAllowed(scopedAllowlist, commandId)) {
            return {
              'error': 'Command not allowed: $commandId',
              'allowed_commands': scopedAllowlist.toList()..sort(),
            };
          }
          if (ns is ContextNamespace) ns.agentId = agentId;
          if (ns is ChatNamespace) {
            ns.agentId = agentId;
          }
          if (ns is WorkflowNamespace) {
            final chId = flags['channel_id'];
            if (chId != null) {
              ns.setContext(chId, agentId);
            }
          }
          return ns.execute(subcommand, flags);
        },
      );
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  // ── Help ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildHelpResult() {
    final result = <String, dynamic>{
      'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
      'hint': 'Call "shepaw <namespace>" to see available sub-commands. '
              'Add flags={"help":""} to any command for detailed usage.',
      'namespaces': {
        for (final entry in _namespaces.entries)
          if (entry.value is! HelpNamespace)
            entry.key: entry.value.description,
      },
    };

    // 添加外部工具信息
    final externalNs = _namespaces.entries
        .where((e) => e.value is ExternalCliNamespace)
        .toList();
    if (externalNs.isNotEmpty) {
      result['external_tools'] = {
        for (final e in externalNs)
          e.key: e.value.description,
      };
    }

    return result;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// 日志脱敏：API Key / token / password 等敏感 flag 值不落日志。
  ///
  /// 不做全量 key 名（如 memory `--key soul` 是普通字段）；只处理明确表示
  /// 凭据的 flag。
  Map<String, String> _redactSensitiveFlags(Map<String, String> flags) {
    if (flags.isEmpty) return flags;
    const sensitiveKeys = {'api_key', 'token', 'password', 'secret'};
    if (!flags.keys.any(sensitiveKeys.contains)) return flags;
    final copy = Map<String, String>.from(flags);
    for (final key in copy.keys.toList()) {
      final v = copy[key];
      if (sensitiveKeys.contains(key) && v != null && v.isNotEmpty) {
        copy[key] = '<redacted>';
      }
    }
    return copy;
  }

  /// 构建命令 ID（用于权限检查）
  /// 格式：namespace.subcommand（如 'context.profile.query'）
  String _buildCommandId(String namespace, String subcommand) {
    if (subcommand.isEmpty) return namespace;
    // subcommand 中的 '.' 在内部已是分隔符，保持原样
    return '$namespace.$subcommand';
  }

  Map<String, String> _parseFlags(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    // 兼容小模型将 flags 传为字符串的情况（如 "--query 你好 --limit 5"）
    if (raw is String) {
      return _parseFlagsFromString(raw);
    }
    return {};
  }

  /// 解析命令行风格的 flags 字符串
  ///
  /// 支持格式：
  ///   --key value        （标准双横线）
  ///   -key value         （单横线）
  ///   --key=value        （等号赋值）
  ///   --key              （布尔 flag，值为空字符串）
  ///
  /// 示例：
  ///   "--query 你好 --limit 5"   → {'query': '你好', 'limit': '5'}
  ///   "--url https://x.com"     → {'url': 'https://x.com'}
  ///   "--flag"                   → {'flag': ''}
  ///   `--key "a b"` / `--key ""` → 引号被剥掉（空串仍是空串，可用来清列）
  /// 剥掉值两侧的成对引号。
  ///
  /// flags 以字符串形态传入时（小模型常见）无法做 shell 分词：`--system-prompt ""`
  /// 会被切成 `--system-prompt` + `""`，引号本身变成值的一部分写进提示词。
  /// 只剥首尾成对且长度 ≥2 的引号，值内部的引号原样保留。
  static String _stripQuotes(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  Map<String, String> _parseFlagsFromString(String raw) {
    final result = <String, String>{};
    if (raw.trim().isEmpty) return result;

    // 先尝试 JSON 对象解析（兼容 LLM 传 JSON 字符串的情况）
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}

    // 按 --key 或 -key 分割，提取 key-value 对
    // 正则：匹配 --key=value 或 --key（后面跟空格+非--开头的值）
    final tokens = raw.trim().split(RegExp(r'\s+'));
    int i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.startsWith('-')) {
        final key = token.replaceFirst(RegExp(r'^--?'), '');
        // --key=value 格式
        if (key.contains('=')) {
          final eq = key.indexOf('=');
          result[key.substring(0, eq)] = key.substring(eq + 1);
          i++;
          continue;
        }
        // --key value 格式（下一个 token 不以 - 开头）
        if (i + 1 < tokens.length && !tokens[i + 1].startsWith('-')) {
          // 收集所有连续的非-flag token 作为 value（支持带空格的值）
          final valueParts = <String>[];
          int j = i + 1;
          while (j < tokens.length && !tokens[j].startsWith('-')) {
            valueParts.add(tokens[j]);
            j++;
          }
          result[key] = _stripQuotes(valueParts.join(' '));
          i = j;
          continue;
        }
        // 布尔 flag（无值）
        result[key] = '';
        i++;
      } else {
        // 跳过非 flag token（可能是命令路径残留，如 "shepaw tools web.search"）
        i++;
      }
    }
    return result;
  }
}
