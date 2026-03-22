import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/acp_protocol.dart';
import '../../models/llm_stream_event.dart';
import '../local_database_service.dart';
import '../local_llm_agent_service.dart';
import '../acp_agent_connection.dart';
import '../logger_service.dart';

/// Handles admin-mediated interaction decisions and group system message persistence.
class GroupInteractionHandler {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final Map<String, ACPAgentConnection> _acpConnections;
  final void Function(String channelId) notifyChannelUpdate;
  final Future<List<Message>> Function(String channelId, {int limit}) loadChannelMessages;

  GroupInteractionHandler({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, ACPAgentConnection> acpConnections,
    required this.notifyChannelUpdate,
    required this.loadChannelMessages,
  })  : _db = db,
        _uuid = uuid,
        _acpConnections = acpConnections;

  // ---------------------------------------------------------------------------
  // Admin interaction resolution
  // ---------------------------------------------------------------------------

  /// Format a sub-agent interaction request into a text question for the admin LLM.
  String formatInteractionForAdmin({
    required String interactionType,
    required Map<String, dynamic> data,
    required String subAgentName,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('子Agent "$subAgentName" 在执行任务时请求你的决策：');

    switch (interactionType) {
      case 'action_confirmation':
        final title = data['title'] as String? ?? '';
        final message = data['message'] as String? ?? '';
        final actions = data['actions'] as List<dynamic>? ?? [];
        buffer.writeln('类型：操作确认');
        if (title.isNotEmpty) buffer.writeln('标题："$title"');
        if (message.isNotEmpty) buffer.writeln('问题："$message"');
        if (actions.isNotEmpty) {
          buffer.writeln('选项：');
          for (var i = 0; i < actions.length; i++) {
            final action = actions[i] as Map<String, dynamic>;
            final actionId = action['id'] as String? ?? '';
            final label = action['label'] as String? ?? '';
            buffer.writeln('${i + 1}. [$actionId] $label');
          }
        }
        buffer.writeln('请回复选项编号（如"1"）。如果你不确定，请回复 [ASK_USER]。');

      case 'single_select':
        final title = data['title'] as String? ?? '';
        final options = data['options'] as List<dynamic>? ?? [];
        buffer.writeln('类型：单选');
        if (title.isNotEmpty) buffer.writeln('问题："$title"');
        if (options.isNotEmpty) {
          buffer.writeln('选项：');
          for (var i = 0; i < options.length; i++) {
            final option = options[i] as Map<String, dynamic>;
            final optionId = option['id'] as String? ?? '';
            final label = option['label'] as String? ?? '';
            buffer.writeln('${i + 1}. [$optionId] $label');
          }
        }
        buffer.writeln('请回复选项编号（如"1"）。如果你不确定，请回复 [ASK_USER]。');

      case 'multi_select':
        final title = data['title'] as String? ?? '';
        final options = data['options'] as List<dynamic>? ?? [];
        buffer.writeln('类型：多选');
        if (title.isNotEmpty) buffer.writeln('问题："$title"');
        if (options.isNotEmpty) {
          buffer.writeln('选项：');
          for (var i = 0; i < options.length; i++) {
            final option = options[i] as Map<String, dynamic>;
            final optionId = option['id'] as String? ?? '';
            final label = option['label'] as String? ?? '';
            buffer.writeln('${i + 1}. [$optionId] $label');
          }
        }
        buffer.writeln('请回复选项编号（可用逗号分隔多个，如"1,3"）。如果你不确定，请回复 [ASK_USER]。');

      case 'form':
        final title = data['title'] as String? ?? '';
        final fields = data['fields'] as List<dynamic>? ?? [];
        buffer.writeln('类型：表单');
        if (title.isNotEmpty) buffer.writeln('标题："$title"');
        if (fields.isNotEmpty) {
          buffer.writeln('字段：');
          for (final field in fields) {
            final f = field as Map<String, dynamic>;
            buffer.writeln('- ${f['label'] ?? f['id'] ?? 'unknown'}');
          }
        }
        buffer.writeln('表单类型较复杂，请回复 [ASK_USER] 交给用户处理。');

      default:
        buffer.writeln('类型：$interactionType');
        buffer.writeln('请回复 [ASK_USER] 交给用户处理。');
    }

    return buffer.toString();
  }

  /// Try to match admin response text against options by index, ID, or label.
  int matchOption(String response, List<dynamic> options) {
    final trimmed = response.trim();
    final asInt = int.tryParse(trimmed);
    if (asInt != null && asInt >= 1 && asInt <= options.length) {
      return asInt - 1;
    }
    for (var i = 0; i < options.length; i++) {
      final opt = options[i] as Map<String, dynamic>;
      final id = opt['id'] as String? ?? '';
      final label = opt['label'] as String? ?? '';
      if (trimmed.toLowerCase() == id.toLowerCase() ||
          trimmed.toLowerCase() == label.toLowerCase()) {
        return i;
      }
    }
    return -1;
  }

  /// Parse admin LLM response to extract chosen option(s).
  Map<String, dynamic>? parseAdminDecision({
    required String interactionType,
    required String adminResponse,
    required Map<String, dynamic> data,
  }) {
    final trimmed = adminResponse.trim();
    if (trimmed.contains('[ASK_USER]')) return null;

    switch (interactionType) {
      case 'action_confirmation':
        final actions = data['actions'] as List<dynamic>? ?? [];
        if (actions.isEmpty) return null;
        final idx = matchOption(trimmed, actions);
        if (idx < 0) return null;
        final chosen = actions[idx] as Map<String, dynamic>;
        return {
          'confirmation_id': data['confirmation_id'] ?? data['id'] ?? '',
          'selected_action_id': chosen['id'] ?? '',
          'selected_action_label': chosen['label'] ?? '',
        };

      case 'single_select':
        final options = data['options'] as List<dynamic>? ?? [];
        if (options.isEmpty) return null;
        final idx = matchOption(trimmed, options);
        if (idx < 0) return null;
        final chosen = options[idx] as Map<String, dynamic>;
        return {
          'select_id': data['select_id'] ?? data['id'] ?? '',
          'selected_option_id': chosen['id'] ?? '',
          'selected_option_label': chosen['label'] ?? '',
        };

      case 'multi_select':
        final options = data['options'] as List<dynamic>? ?? [];
        if (options.isEmpty) return null;
        final parts = trimmed.split(RegExp(r'[,，\s]+'));
        final selectedIds = <String>[];
        for (final part in parts) {
          final idx = int.tryParse(part.trim());
          if (idx != null && idx >= 1 && idx <= options.length) {
            final opt = options[idx - 1] as Map<String, dynamic>;
            selectedIds.add(opt['id'] as String? ?? '');
          }
        }
        if (selectedIds.isEmpty) return null;
        return {
          'select_id': data['select_id'] ?? data['id'] ?? '',
          'selected_option_ids': selectedIds,
        };

      case 'form':
        return null;

      default:
        return null;
    }
  }

  /// Ask the admin LLM to make a decision on a sub-agent's interaction request.
  Future<Map<String, dynamic>?> resolveInteractionViaAdmin({
    required String interactionType,
    required Map<String, dynamic> data,
    required RemoteAgent adminAgent,
    required String channelId,
    required String subAgentName,
  }) async {
    try {
      final question = formatInteractionForAdmin(
        interactionType: interactionType,
        data: data,
        subAgentName: subAgentName,
      );

      final recentMessages = await loadChannelMessages(channelId, limit: 10);
      final historyLines = recentMessages.map((m) {
        final tag = m.from.isAgent ? 'Agent' : 'User';
        final content = (m.type != MessageType.text && m.type != MessageType.system)
            ? '${m.content} [id:${m.id}]'
            : m.content;
        return '[${m.from.name}($tag)]: $content';
      }).join('\n');

      final history = historyLines.isNotEmpty
          ? <Map<String, dynamic>>[
              {'role': 'user', 'content': '以下是群聊的近期记录：\n$historyLines'},
            ]
          : <Map<String, dynamic>>[];

      const decisionSystemPrompt = '你正在代替用户为子Agent的交互请求做决策。\n'
          '根据群聊上下文和子Agent的请求，选择最合适的选项。\n'
          '规则：\n'
          '- 只回复选项编号（如"1"），不要解释\n'
          '- 如果你确实无法判断，回复 [ASK_USER]\n'
          '- 优先选择能推进任务完成的选项';

      final responseBuffer = StringBuffer();
      await for (final event in LocalLLMAgentService.instance.chat(
        agent: adminAgent,
        message: question,
        history: history.isNotEmpty ? history : null,
        enableUITools: false,
        systemPromptOverride: decisionSystemPrompt,
      ).timeout(const Duration(seconds: 30))) {
        if (event is LLMTextEvent) {
          responseBuffer.write(event.text);
        }
      }

      final adminResponse = responseBuffer.toString().trim();
      if (adminResponse.isEmpty) return null;

      LoggerService().debug(
        'Admin decision for $subAgentName ($interactionType): "$adminResponse"',
        tag: 'GroupInteractionHandler',
      );

      return parseAdminDecision(
        interactionType: interactionType,
        adminResponse: adminResponse,
        data: data,
      );
    } catch (e) {
      LoggerService().error('resolveInteractionViaAdmin error', tag: 'GroupInteractionHandler', error: e);
      return null;
    }
  }

  /// Pick a safe default option when the admin LLM cannot decide.
  Map<String, dynamic>? pickDefaultOption(String interactionType, Map<String, dynamic> data) {
    switch (interactionType) {
      case 'action_confirmation':
        final actions = data['actions'] as List<dynamic>? ?? [];
        if (actions.isEmpty) return null;
        var chosen = actions[0] as Map<String, dynamic>;
        for (final action in actions) {
          final a = action as Map<String, dynamic>;
          if (a['style'] == 'primary') {
            chosen = a;
            break;
          }
        }
        return {
          'confirmation_id': data['confirmation_id'] ?? data['id'] ?? '',
          'selected_action_id': chosen['id'] ?? '',
          'selected_action_label': chosen['label'] ?? '',
        };

      case 'single_select':
        final options = data['options'] as List<dynamic>? ?? [];
        if (options.isEmpty) return null;
        final chosen = options[0] as Map<String, dynamic>;
        return {
          'select_id': data['select_id'] ?? data['id'] ?? '',
          'selected_option_id': chosen['id'] ?? '',
          'selected_option_label': chosen['label'] ?? '',
        };

      case 'multi_select':
        final options = data['options'] as List<dynamic>? ?? [];
        if (options.isEmpty) return null;
        final first = options[0] as Map<String, dynamic>;
        return {
          'select_id': data['select_id'] ?? data['id'] ?? '',
          'selected_option_ids': [first['id'] ?? ''],
        };

      case 'form':
        LoggerService().debug('Cannot auto-fill form interaction, skipping', tag: 'GroupInteractionHandler');
        return null;

      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Group system message persistence
  // ---------------------------------------------------------------------------

  /// Save a system message recording an admin's auto-decision in the group chat.
  void saveAdminDecisionMessage({
    required String channelId,
    required String subAgentName,
    required String interactionType,
    required String chosenLabel,
  }) {
    () async {
      try {
        final msgId = _uuid.v4();
        final typeLabel = switch (interactionType) {
          'action_confirmation' => '操作确认',
          'single_select' => '单选',
          'multi_select' => '多选',
          _ => interactionType,
        };
        final content = '[系统] 管理员代替用户为 $subAgentName 做出了决策（$typeLabel）：选择"$chosenLabel"';
        await _db.createMessage(
          id: msgId,
          channelId: channelId,
          senderId: 'system',
          senderType: 'system',
          senderName: 'System',
          content: content,
          messageType: 'system',
        );
        await _db.markMessageAsRead(msgId);
        notifyChannelUpdate(channelId);
      } catch (e) {
        LoggerService().error('Failed to save admin decision message', tag: 'GroupInteractionHandler', error: e);
      }
    }();
  }

  /// Save a system message recording the result of a user interaction for a
  /// local LLM member agent.
  void saveUserInteractionResultMessage({
    required String channelId,
    required String subAgentName,
    required String interactionType,
    required Map<String, dynamic>? responseData,
  }) {
    () async {
      try {
        final msgId = _uuid.v4();
        final typeLabel = switch (interactionType) {
          'action_confirmation' => '操作确认',
          'single_select' => '单选',
          'multi_select' => '多选',
          'form' => '表单',
          'file_upload' => '文件上传',
          _ => interactionType,
        };

        final String content;
        if (responseData == null) {
          content = '[SYSTEM] $subAgentName 输出了一个$typeLabel，但用户未在规定时间内提交。'
              '请重新确认该成员的任务是否完成，或需要重新委派。';
        } else {
          final summary = switch (interactionType) {
            'action_confirmation' =>
              responseData['selected_action_label'] as String? ??
                  responseData['selected_action_id'] as String? ?? '(unknown)',
            'single_select' =>
              responseData['selected_option_label'] as String? ??
                  responseData['selected_option_id'] as String? ?? '(unknown)',
            'multi_select' =>
              (responseData['selected_option_ids'] as List<dynamic>? ?? []).join(', '),
            'form' =>
              (responseData['submitted_values'] as Map?)
                  ?.entries.map((e) => '${e.key}: ${e.value}').join(', ') ?? '(submitted)',
            _ => responseData.toString(),
          };
          content = '[SYSTEM] 用户已为 $subAgentName 提交了$typeLabel响应：$summary。'
              '请根据此信息判断该成员的任务是否已完成，或是否需要重新委派以继续处理。';
        }

        await _db.createMessage(
          id: msgId,
          channelId: channelId,
          senderId: 'system',
          senderType: 'system',
          senderName: 'System',
          content: content,
          messageType: 'text',
        );
        await _db.markMessageAsRead(msgId);
        notifyChannelUpdate(channelId);
      } catch (e) {
        LoggerService().error('Failed to save user interaction result message',
            tag: 'GroupInteractionHandler', error: e);
      }
    }();
  }

  /// Notify group members about a membership change (join/leave).
  Future<Message> notifyGroupMembershipChange(
    String channelId,
    String memberId,
    String memberName, {
    required bool isJoin,
  }) async {
    final channel = await _db.getChannelById(channelId);
    final groupName = channel?.name ?? 'Group';

    final action = isJoin ? '加入了群聊' : '离开了群聊';
    final systemMessage = Message(
      id: _uuid.v4(),
      content: '🤖 $memberName $action',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
    );

    await _db.createMessage(
      id: systemMessage.id,
      channelId: channelId,
      senderId: 'system',
      senderType: 'system',
      senderName: 'System',
      content: systemMessage.content,
      messageType: 'system',
    );
    await _db.markMessageAsRead(systemMessage.id);
    notifyChannelUpdate(channelId);

    final memberIds = await _db.getChannelMemberIds(channelId);
    final List<Map<String, dynamic>> currentMembers = [];
    for (final id in memberIds) {
      final agent = await _db.getRemoteAgentById(id);
      if (agent != null) {
        currentMembers.add({
          'id': agent.id,
          'name': agent.name,
          'type': 'agent',
          'bio': agent.bio ?? '',
          'capabilities': agent.capabilities,
          'status': agent.status.name,
        });
      }
    }

    final method = isJoin ? ACPMethod.groupMemberJoined : ACPMethod.groupMemberLeft;
    final params = {
      'group_id': channelId,
      'group_name': groupName,
      'member': {'id': memberId, 'name': memberName},
      'current_members': currentMembers,
      'member_count': currentMembers.length,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    for (final id in memberIds) {
      final connection = _acpConnections[id];
      if (connection != null && connection.isConnected) {
        connection.sendNotification(method, params: params);
      }
    }

    return systemMessage;
  }
}
