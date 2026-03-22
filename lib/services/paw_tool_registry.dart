import 'dart:convert';
import 'local_database_service.dart';
import 'she_profile_database_service.dart';
import 'os_tool_registry.dart';
import 'skill_registry.dart';
import 'she_service.dart';
import 'logger_service.dart';
import '../models/remote_agent.dart';

/// PawToolRegistry — She 专属的内嵌 CLI 工具。
///
/// 注册为原生 LLM function-calling 工具（单个 "shepaw" function），
/// She 通过结构化调用查询和写入 ShePaw 本地数据，替代文本标记方式。
///
/// CLI 风格：
///   shepaw <namespace> <subcommand> [--flag value ...]
///
/// 命名空间：
///   profile   主人档案（user_profile 表）
///   memory    She 的记忆（she_memory 表）
///   agents    已添加的 AI 助手
///   channels  对话频道
///   messages  频道消息
///   skills    技能列表
///   tools     系统工具（OS tools）
///   help      顶层帮助

/// Minimal interface that PawToolRegistry needs to send messages as She.
/// Fulfilled by ChatService — defined here to avoid a circular import.
abstract class IPawChatSender {
  Future<void> sendAsSheTo({
    required RemoteAgent targetAgent,
    required String channelId,
    required String message,
  });
}

class PawToolRegistry {
  static final PawToolRegistry instance = PawToolRegistry._();
  PawToolRegistry._();

  static const String toolName = 'shepaw';

  final _db = LocalDatabaseService();
  final _profileDb = SheProfileDatabaseService();

  /// Injected by ChatService on startup to enable `shepaw agents chat`.
  IPawChatSender? chatSender;

  // ── Tool Definitions (传给 LLM) ────────────────────────────────────────────

  Map<String, dynamic> openAITool() => {
        'type': 'function',
        'function': {
          'name': toolName,
          'description':
              'ShePaw 内置 CLI：查询和写入主人档案、She 记忆、Agent 列表、频道消息等本地数据。'
              '运行 shepaw help 获取完整命令列表。',
          'parameters': {
            'type': 'object',
            'properties': {
              'namespace': {
                'type': 'string',
                'enum': [
                  'profile',
                  'memory',
                  'agents',
                  'channels',
                  'messages',
                  'skills',
                  'tools',
                  'help',
                ],
                'description': '命令命名空间',
              },
              'subcommand': {
                'type': 'string',
                'description':
                    '子命令。profile: fields|query|write|delete；'
                    'memory: query|write|append；'
                    'agents: list|get|channels|messages|chat；'
                    'channels: list；'
                    'messages: query；'
                    'skills: list；'
                    'tools: list；'
                    'help: （无需子命令）',
              },
              'flags': {
                'type': 'object',
                'description':
                    '命令参数，键值对。常用参数：'
                    'field（profile字段名）、value（写入值）、'
                    'fields（逗号分隔的字段列表）、'
                    'key（memory键名）、'
                    'id（agent ID）、status（online/offline/all）、'
                    'channel（频道ID）、agent（agent ID，messages query 时与 channel 二选一）、'
                    'limit（条数，默认20）、offset（跳过条数，默认0，用于翻页）、'
                    'message（agents chat 要发送的消息内容）',
                'additionalProperties': {'type': 'string'},
              },
            },
            'required': ['namespace'],
          },
        },
      };

  Map<String, dynamic> claudeTool() => {
        'name': toolName,
        'description':
            'ShePaw 内置 CLI：查询和写入主人档案、She 记忆、Agent 列表、频道消息等本地数据。'
            '运行 shepaw help 获取完整命令列表。',
        'input_schema': {
          'type': 'object',
          'properties': {
            'namespace': {
              'type': 'string',
              'enum': [
                'profile',
                'memory',
                'agents',
                'channels',
                'messages',
                'skills',
                'tools',
                'help',
              ],
              'description': '命令命名空间',
            },
            'subcommand': {
              'type': 'string',
              'description':
                  '子命令。profile: fields|query|write|delete；'
                  'memory: query|write|append；'
                  'agents: list|get|channels|messages|chat；'
                  'channels: list；'
                  'messages: query；'
                  'skills: list；'
                  'tools: list；'
                  'help: （无需子命令）',
            },
            'flags': {
              'type': 'object',
              'description':
                  '命令参数，键值对。常用参数：'
                  'field（profile字段名）、value（写入值）、'
                  'fields（逗号分隔的字段列表）、'
                  'key（memory键名）、'
                  'id（agent ID）、status（online/offline/all）、'
                  'channel（频道ID）、agent（agent ID，messages query 时与 channel 二选一）、'
                  'limit（条数，默认20）、offset（跳过条数，默认0，用于翻页）、'
                  'message（agents chat 要发送的消息内容）',
              'additionalProperties': {'type': 'string'},
            },
          },
          'required': ['namespace'],
        },
      };

  bool isPawTool(String name) => name == toolName;

  // ── Command Dispatch ────────────────────────────────────────────────────────

  /// 执行 shepaw 命令，返回 JSON 字符串结果（供 LLM tool_result 使用）。
  Future<String> execute(Map<String, dynamic> args) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);

    LoggerService().info(
        'shepaw $namespace ${subcommand.isNotEmpty ? subcommand : ""} $flags',
        tag: 'Paw');

    try {
      final result = await _dispatch(namespace, subcommand, flags);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  Map<String, String> _parseFlags(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return {};
  }

  Future<Map<String, dynamic>> _dispatch(
    String namespace,
    String subcommand,
    Map<String, String> flags,
  ) async {
    switch (namespace) {
      case 'profile':
        return _profile(subcommand, flags);
      case 'memory':
        return _memory(subcommand, flags);
      case 'agents':
        return _agents(subcommand, flags);
      case 'channels':
        return _channels(subcommand, flags);
      case 'messages':
        return _messages(subcommand, flags);
      case 'skills':
        return _skills(subcommand, flags);
      case 'tools':
        return _tools(subcommand, flags);
      case 'help':
      default:
        return _help();
    }
  }

  // ── profile ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _profile(
      String sub, Map<String, String> flags) async {
    switch (sub) {
      case 'fields':
        return {
          'fields': {
            'name': '姓名',
            'age': '年龄',
            'gender': '性别',
            'occupation': '职业',
            'city': '所在城市',
            'interests': '兴趣爱好',
            'values': '价值观',
            'goals': '目标与需求',
            'communication_style': '沟通风格',
            'work_style': '工作习惯',
            'life_stage': '人生阶段',
            'important_people': '重要的人',
            'health': '健康状况',
            'language': '语言偏好',
            'timezone': '时区',
            'notes': '其他备注',
          },
          'note': '以上为预定义字段，你也可以自由写入任意自定义字段（如 pet_name、hobby_music 等）',
        };

      case 'query':
        final allProfile = await _profileDb.getAllUserProfile();
        // 过滤内部标志字段
        final visible = Map.fromEntries(
          allProfile.entries.where((e) => !e.key.startsWith('_')),
        );
        final fieldsArg = flags['fields'];
        if (fieldsArg != null && fieldsArg.isNotEmpty) {
          final requested = fieldsArg.split(',').map((s) => s.trim()).toSet();
          final filtered = Map.fromEntries(
            visible.entries.where((e) => requested.contains(e.key)),
          );
          return {'profile': filtered, 'count': filtered.length};
        }
        return {'profile': visible, 'count': visible.length};

      case 'write':
        final field = flags['field'];
        final value = flags['value'];
        if (field == null || field.isEmpty) {
          return {'error': '缺少 --field 参数。用法：shepaw profile write --field name --value 小明'};
        }
        if (value == null) {
          return {'error': '缺少 --value 参数。用法：shepaw profile write --field name --value 小明'};
        }
        await SheService.instance.updateUserProfileField(field, value);
        return {'ok': true, 'field': field, 'value': value};

      case 'delete':
        final field = flags['field'];
        if (field == null || field.isEmpty) {
          return {'error': '缺少 --field 参数。用法：shepaw profile delete --field name'};
        }
        await _profileDb.deleteUserProfile(field);
        return {'ok': true, 'deleted': field};

      default:
        return {
          'error': '未知子命令：$sub',
          'usage': 'shepaw profile <fields|query|write|delete> [--flags]',
          'examples': [
            'shepaw profile fields',
            'shepaw profile query',
            'shepaw profile query --fields name,age,occupation',
            'shepaw profile write --field name --value 小明',
            'shepaw profile delete --field notes',
          ],
        };
    }
  }

  // ── memory ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _memory(
      String sub, Map<String, String> flags) async {
    switch (sub) {
      case 'query':
        final allMemory = await _profileDb.getAllSheMemory();
        final keysArg = flags['keys'];
        if (keysArg != null && keysArg.isNotEmpty) {
          final requested = keysArg.split(',').map((s) => s.trim()).toSet();
          final filtered =
              Map.fromEntries(allMemory.entries.where((e) => requested.contains(e.key)));
          return {'memory': filtered};
        }
        return {'memory': allMemory};

      case 'write':
        final key = flags['key'];
        final value = flags['value'];
        if (key == null || key.isEmpty) {
          return {'error': '缺少 --key 参数。用法：shepaw memory write --key soul --value "..."'};
        }
        if (value == null) {
          return {'error': '缺少 --value 参数'};
        }
        // 路由到 SheService 的专用方法
        if (key == 'soul') {
          await SheService.instance.updateSoul(value);
        } else {
          await _profileDb.setSheMemory(key, value);
        }
        return {'ok': true, 'key': key};

      case 'append':
        final key = flags['key'];
        final value = flags['value'];
        if (key == null || key.isEmpty) {
          return {'error': '缺少 --key 参数。用法：shepaw memory append --key long_term_memory --value "..."'};
        }
        if (value == null) {
          return {'error': '缺少 --value 参数'};
        }
        if (key == 'long_term_memory') {
          await SheService.instance.appendMemory(value);
        } else {
          await SheService.instance.appendSelfNote(value);
        }
        return {'ok': true, 'key': key, 'appended': value};

      default:
        return {
          'error': '未知子命令：$sub',
          'usage': 'shepaw memory <query|write|append> [--flags]',
          'keys': [
            'soul（你的自我认知，整段替换）',
            'self_notes（自我备注，追加用 append）',
            'long_term_memory（长期记忆，追加用 append）',
            'heartbeat（上次对话摘要）',
            'user_info（对主人的整体印象）',
            'capabilities（能力索引）',
          ],
          'examples': [
            'shepaw memory query',
            'shepaw memory query --keys soul,user_info',
            'shepaw memory write --key soul --value "我是..."',
            'shepaw memory append --key long_term_memory --value "主人提到了..."',
          ],
        };
    }
  }

  // ── agents ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _agents(
      String sub, Map<String, String> flags) async {
    switch (sub) {
      case 'list':
      case '':
        var agents = await _db.getAllRemoteAgents();
        final statusFilter = flags['status'];
        if (statusFilter != null && statusFilter != 'all') {
          agents = agents
              .where((a) => a.status.name.toLowerCase() == statusFilter.toLowerCase())
              .toList();
        }
        final list = agents.map((a) => {
              'id': a.id,
              'name': a.name,
              'bio': a.bio,
              'status': a.status.name,
              'is_she': a.metadata['is_she'] == true,
              'provider': a.metadata['llm_provider'],
              'model': a.metadata['llm_model'],
            }).toList();
        return {'agents': list, 'count': list.length};

      case 'get':
        final id = flags['id'];
        if (id == null || id.isEmpty) {
          return {'error': '缺少 --id 参数。用法：shepaw agents get --id <agent_id>'};
        }
        final agent = await _db.getRemoteAgentById(id);
        if (agent == null) {
          return {'error': '找不到 Agent：$id'};
        }
        return {
          'id': agent.id,
          'name': agent.name,
          'bio': agent.bio,
          'status': agent.status.name,
          'endpoint': agent.endpoint,
          'protocol': agent.protocol.name,
          'is_pinned': agent.isPinned,
          'is_she': agent.metadata['is_she'] == true,
          'provider': agent.metadata['llm_provider'],
          'model': agent.metadata['llm_model'],
          'created_at': agent.createdAt,
        };

      case 'channels':
        final id = flags['id'];
        if (id == null || id.isEmpty) {
          return {'error': '缺少 --id 参数。用法：shepaw agents channels --id <agent_id>'};
        }
        final agentChannels = await _db.getChannelsForAgent(id);
        final channelList = agentChannels.map((c) => {
              'id': c.id,
              'name': c.name,
              'type': c.type,
              'description': c.description,
              'last_message': c.lastMessage,
              'last_message_at': c.lastMessageTime?.toIso8601String(),
            }).toList();
        return {'agent_id': id, 'channels': channelList, 'count': channelList.length};

      case 'messages':
        final id = flags['id'];
        if (id == null || id.isEmpty) {
          return {'error': '缺少 --id 参数。用法：shepaw agents messages --id <agent_id> [--channel <channel_id>] [--limit 20] [--offset 0]'};
        }
        // Resolve channel: explicit flag > most recent She↔agent DM > any channel the agent is in
        String? channelId = flags['channel'];
        if (channelId == null || channelId.isEmpty) {
          channelId = await _db.getLatestActiveChannelForUserAndAgent(SheService.sheId, id);
          if (channelId == null || channelId.isEmpty) {
            final agentChans = await _db.getChannelsForAgent(id);
            if (agentChans.isNotEmpty) channelId = agentChans.first.id;
          }
        }
        if (channelId == null || channelId.isEmpty) {
          return {'error': '没有找到与 agent $id 的对话频道。请先开启对话，或通过 --channel 指定频道 ID。'};
        }
        final msgsLimit = int.tryParse(flags['limit'] ?? '20') ?? 20;
        final msgsOffset = int.tryParse(flags['offset'] ?? '0') ?? 0;
        final agentMsgs = await _db.getChannelMessages(channelId,
            limit: msgsLimit, offset: msgsOffset);
        final agentMsgList = agentMsgs.map((m) {
          final content = (m['content'] as String? ?? '');
          final snippet =
              content.length > 200 ? '${content.substring(0, 200)}…' : content;
          return {
            'id': m['id'],
            'sender': m['sender_name'] ?? m['sender_id'],
            'sender_id': m['sender_id'],
            'role': m['sender_type'],
            'content': snippet,
            'created_at': m['created_at'],
          };
        }).toList();
        return {
          'agent_id': id,
          'channel_id': channelId,
          'limit': msgsLimit,
          'offset': msgsOffset,
          'count': agentMsgList.length,
          'messages': agentMsgList,
        };

      case 'chat':
        final id = flags['id'];
        final message = flags['message'];
        if (id == null || id.isEmpty) {
          return {'error': '缺少 --id 参数。用法：shepaw agents chat --id <agent_id> --message <text> [--channel <channel_id>]'};
        }
        if (message == null || message.isEmpty) {
          return {'error': '缺少 --message 参数。用法：shepaw agents chat --id <agent_id> --message <text>'};
        }
        final targetAgent = await _db.getRemoteAgentById(id);
        if (targetAgent == null) {
          return {'error': '找不到 Agent：$id'};
        }
        // Determine channel: use explicit flag, or find the most recently active channel for this agent
        String? channelId = flags['channel']?.isNotEmpty == true ? flags['channel'] : null;
        if (channelId == null) {
          // Use the agent's own channel list (not tied to She's user ID)
          final agentChans = await _db.getChannelsForAgent(id);
          if (agentChans.isNotEmpty) channelId = agentChans.first.id;
        }
        if (channelId == null || channelId.isEmpty) {
          return {'error': '没有找到与 ${targetAgent.name} 的对话频道。请先在 ShePaw 中开启对话，或通过 --channel 指定频道 ID。'};
        }
        final sender = chatSender;
        if (sender == null) {
          return {'error': 'chatSender 未初始化，无法发送消息'};
        }
        await sender.sendAsSheTo(
          targetAgent: targetAgent,
          channelId: channelId,
          message: message,
        );
        return {
          'ok': true,
          'sent_to': targetAgent.name,
          'channel_id': channelId,
          'message_preview': message.length > 80 ? '${message.substring(0, 80)}…' : message,
        };

      default:
        return {
          'error': '未知子命令：$sub',
          'usage': 'shepaw agents <list|get|channels|messages|chat> [--flags]',
          'examples': [
            'shepaw agents list',
            'shepaw agents list --status online',
            'shepaw agents get --id <agent_id>',
            'shepaw agents channels --id <agent_id>',
            'shepaw agents messages --id <agent_id>',
            'shepaw agents messages --id <agent_id> --channel <channel_id> --limit 20 --offset 0',
            'shepaw agents chat --id <agent_id> --message "你好" [--channel <channel_id>]',
          ],
        };
    }
  }

  // ── channels ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _channels(
      String sub, Map<String, String> flags) async {
    final channels = await _db.getAllChannels();
    final list = channels.map((c) => {
          'id': c.id,
          'name': c.name,
          'type': c.type,
          'description': c.description,
        }).toList();
    return {'channels': list, 'count': list.length};
  }

  // ── messages ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _messages(
      String sub, Map<String, String> flags) async {
    // 支持两种定位方式：
    //   --channel <id>          直接指定频道
    //   --agent  <agent_id>     自动找 She ↔ agent 最近的 DM 频道
    String? channelId = flags['channel'];

    if (channelId == null || channelId.isEmpty) {
      final agentId = flags['agent'];
      if (agentId != null && agentId.isNotEmpty) {
        channelId = await _db.getLatestActiveChannelForUserAndAgent(
            SheService.sheId, agentId);
        if (channelId == null || channelId.isEmpty) {
          return {
            'error': '没有找到与 agent $agentId 的对话频道。'
                '请先在 ShePaw 中开启对话，或通过 --channel 直接指定频道 ID。'
          };
        }
      } else {
        return {
          'error': '需要提供 --channel <channel_id> 或 --agent <agent_id>。\n'
              '用法：\n'
              '  shepaw messages query --channel <id> [--limit 20] [--offset 0]\n'
              '  shepaw messages query --agent <agent_id> [--limit 20] [--offset 0]'
        };
      }
    }

    final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final offset = int.tryParse(flags['offset'] ?? '0') ?? 0;

    final msgs = await _db.getChannelMessages(channelId,
        limit: limit, offset: offset);

    final list = msgs.map((m) {
      final content = (m['content'] as String? ?? '');
      final snippet =
          content.length > 200 ? '${content.substring(0, 200)}…' : content;
      return {
        'id': m['id'],
        'sender': m['sender_name'] ?? m['sender_id'],
        'sender_id': m['sender_id'],
        'role': m['sender_type'],
        'content': snippet,
        'created_at': m['created_at'],
      };
    }).toList();

    return {
      'channel_id': channelId,
      'limit': limit,
      'offset': offset,
      'count': list.length,
      'messages': list,
    };
  }

  // ── skills ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _skills(
      String sub, Map<String, String> flags) async {
    final skills = SkillRegistry.instance.skills;
    final list = skills.map((s) => {
          'tool_name': s.toolName,
          'display_name': s.displayName,
          'description': s.description,
        }).toList();
    return {'skills': list, 'count': list.length};
  }

  // ── tools ────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _tools(
      String sub, Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final tools = registry.tools
        .where((t) => t.supportedPlatforms.contains(platform))
        .toList();
    final list = tools.map((t) => {
          'name': t.name,
          'description': t.description,
          'category': t.category,
          'risk': t.defaultRiskLevel,
        }).toList();
    return {'platform': platform, 'tools': list, 'count': list.length};
  }

  // ── help ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _help() => {
        'cli': 'shepaw <namespace> <subcommand> [--flag value ...]',
        'namespaces': {
          'profile': {
            'desc': '主人档案（user_profile 表）',
            'subcommands': {
              'fields': '列出所有预定义字段及描述',
              'query': '查询档案，可选 --fields name,age,...',
              'write': '写入字段，--field <key> --value <val>',
              'delete': '删除字段，--field <key>',
            },
          },
          'memory': {
            'desc': 'She 的记忆（she_memory 表）',
            'subcommands': {
              'query': '查询记忆，可选 --keys soul,heartbeat,...',
              'write': '写入记忆，--key <key> --value <val>',
              'append': '追加内容，--key long_term_memory|self_notes --value <val>',
            },
            'keys': ['soul', 'self_notes', 'long_term_memory', 'heartbeat', 'user_info', 'capabilities'],
          },
          'agents': {
            'desc': '已添加的 AI 助手',
            'subcommands': {
              'list': '列出助手，可选 --status online|offline|all',
              'get': '获取详情，--id <agent_id>',
              'channels': '列出某 agent 的所有对话频道，--id <agent_id>',
              'messages': '读取某 agent 某频道的消息，--id <agent_id> [--channel <id>] [--limit N] [--offset N]',
              'chat': '以 She 身份向 agent 发消息，--id <agent_id> --message <text> [--channel <id>]',
            },
          },
          'channels': {
            'desc': '对话频道列表',
            'subcommands': {'list': '列出所有频道'},
          },
          'messages': {
            'desc': '频道消息',
            'subcommands': {
              'query': '查询消息，--channel <id> 或 --agent <agent_id>，可选 --limit N（默认20）--offset N（默认0）',
            },
          },
          'skills': {
            'desc': '已加载的技能',
            'subcommands': {'list': '列出所有技能'},
          },
          'tools': {
            'desc': '当前平台可用的系统工具',
            'subcommands': {'list': '列出工具'},
          },
        },
        'examples': [
          'shepaw help',
          'shepaw profile fields',
          'shepaw profile query',
          'shepaw profile write --field name --value 小明',
          'shepaw memory query --keys soul,user_info',
          'shepaw memory write --key soul --value "我是..."',
          'shepaw memory append --key long_term_memory --value "今天主人聊到了..."',
          'shepaw agents list --status online',
          'shepaw agents channels --id <agent_id>',
          'shepaw agents messages --id <agent_id>',
          'shepaw agents messages --id <agent_id> --channel <channel_id> --limit 20 --offset 20',
          'shepaw agents chat --id <agent_id> --message "你好，有个问题想问你"',
          'shepaw messages query --channel abc123 --limit 10',
          'shepaw messages query --agent <agent_id> --limit 20 --offset 0',
        ],
      };
}
