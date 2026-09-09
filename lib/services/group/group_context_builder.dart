import 'dart:convert';

import '../../models/acp_protocol.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import 'group_member_history.dart';
import 'group_prompt_builder.dart';

/// Builds the machine-readable `group_context` payload sent to remote / peer
/// agents on each group turn, and helpers for human-readable mention hints.
class GroupContextBuilder {
  GroupContextBuilder._();

  /// JSON Schema fragment for a single mention entry (shared by prompt,
  /// `group_context.member_mention`, and persisted message metadata).
  static Map<String, dynamic> mentionEntrySchema() => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description':
                'Member registered name from group_context.members[].name, '
                'or "all" for every member.',
          },
          'notify': {
            'type': 'boolean',
            'description':
                'true = activate the member for a reply; false = cc-only.',
            'default': true,
          },
          'reason': {
            'type': 'string',
            'description':
                'Optional: why this member is needed (shown to them).',
          },
        },
        'required': ['name'],
      };

  /// Full mentions payload shape accepted by Shepaw orchestration.
  static Map<String, dynamic> mentionsPayloadSchema() => {
        'type': 'object',
        'properties': {
          'mentions': {
            'type': 'array',
            'items': mentionEntrySchema(),
            'minItems': 1,
          },
        },
        'required': ['mentions'],
      };

  static Map<String, dynamic> _exampleMentionPayload(String exampleName) => {
        'mentions': [
          {
            'name': exampleName,
            'notify': true,
            'reason': '需要你的专业能力协助完成子任务',
          },
        ],
      };

  /// How a non-admin member should declare mentions for [agent].
  static Map<String, dynamic> memberMentionContract({
    required RemoteAgent agent,
    required String exampleMemberName,
  }) {
    if (agent.isLocal && !agent.isPeerAgent) {
      return {
        'enabled': true,
        'transport': 'tool',
        'tool_name': 'group_mention',
        'schema': mentionsPayloadSchema(),
        'example': _exampleMentionPayload(exampleMemberName),
      };
    }
    if (agent.isPeerAgent) {
      return {
        'enabled': true,
        'transport': 'reply_metadata',
        'peer_event': 'agent_metadata',
        'schema': mentionsPayloadSchema(),
        'example': _exampleMentionPayload(exampleMemberName),
        'notes': [
          'Include the mentions payload in the turn reply metadata '
              '(agent_metadata event). Do not rely on @name in chat text.',
        ],
      };
    }
    return {
      'enabled': true,
      'transport': 'acp_notification',
      'acp_method': ACPMethod.uiMessageMetadata,
      'schema': mentionsPayloadSchema(),
      'example': _exampleMentionPayload(exampleMemberName),
      'notes': [
        'Send an ACP notification ui.messageMetadata whose params include '
            'the mentions payload. Chat text @name is display-only.',
      ],
    };
  }

  /// One-line hint for the group system prompt 【协作提及】 section.
  static String mentionDeclarationHint(RemoteAgent agent) {
    if (agent.isLocal && !agent.isPeerAgent) {
      return '调用 `group_mention` 工具，参数：'
          '`${jsonEncode(_exampleMentionPayload('成员注册名'))}`';
    }
    if (agent.isPeerAgent) {
      return '在回合结束的 reply metadata（`agent_metadata` 事件）中附带 '
          'mentions 声明：`${jsonEncode(_exampleMentionPayload('成员注册名'))}`';
    }
    return '发送 ACP 通知 `${ACPMethod.uiMessageMetadata}`，params 附带 '
        'mentions 声明：`${jsonEncode(_exampleMentionPayload('成员注册名'))}`';
  }

  static List<Map<String, dynamic>> memberEntries({
    required List<RemoteAgent> allAgents,
    List<ChannelMember> channelMembers = const [],
  }) {
    return allAgents
        .map((a) => <String, dynamic>{
              'id': a.id,
              'name': a.name,
              'type': 'agent',
              'bio': GroupPromptBuilder.oneLineRole(
                a,
                channelMembers: channelMembers,
              ),
              'capabilities': a.capabilities,
              'status': a.isOnline ? 'online' : 'offline',
            })
        .toList();
  }

  /// Build the `group_context` object for ACP / mailbox / peer embedding.
  static Map<String, dynamic> build({
    required String channelId,
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    List<ChannelMember> channelMembers = const [],
    String mentionMode = 'adminOnly',
    bool isAdmin = false,
    bool? isFirstMessage,
    Map<String, dynamic>? messageVersion,
    List<Map<String, dynamic>>? orchestrationTools,
    String? workspaceUri,
    RemoteAgent? currentAgent,
  }) {
    final effectiveMode = mentionMode.isNotEmpty ? mentionMode : 'adminOnly';
    final collaboratorName = allAgents
        .where((a) => a.id != currentAgent?.id)
        .map((a) => a.name)
        .firstOrNull;
    final exampleName = collaboratorName ?? '成员名';

    final ctx = <String, dynamic>{
      'group_id': channelId,
      'group_name': groupName,
      'group_description': groupDescription,
      'member_count': allAgents.length,
      'members': memberEntries(
        allAgents: allAgents,
        channelMembers: channelMembers,
      ),
      'mention_mode': effectiveMode,
      'history_policy': _historyPolicy(isAdmin: isAdmin),
      if (isFirstMessage != null) 'is_first_message': isFirstMessage,
      if (messageVersion != null) 'message_version': messageVersion,
      if (orchestrationTools != null && orchestrationTools.isNotEmpty)
        'orchestration_tools': orchestrationTools,
      if (workspaceUri != null) 'workspace_uri': workspaceUri,
    };

    if (effectiveMode == 'allMembers' && !isAdmin && currentAgent != null) {
      ctx['member_mention'] = memberMentionContract(
        agent: currentAgent,
        exampleMemberName: exampleName,
      );
    }

    return ctx;
  }

  /// Documented exclusions shared by admin and member history policies.
  static const historyPolicyExcludes = [
    'system',
    'permission_audit',
    'metadata.progress_content',
    'collapsible_thinking',
  ];

  static const _historyPolicyNote =
      'Replays message.content (answer text) only. Collapsible thinking and '
      'tool progress live in metadata.progress_content for the chat UI and are '
      'not injected into orchestration history. Task brief and @mention reason '
      'are injected in the user turn, not history.';

  static Map<String, dynamic> _historyPolicy({required bool isAdmin}) {
    if (isAdmin) {
      return {
        'scope': 'full_transcript',
        'max_chars': GroupMemberHistory.adminMaxChars,
        'content_source': 'message.content',
        'includes': ['user', 'agent', 'attachment_placeholders'],
        'excludes': historyPolicyExcludes,
        'note': _historyPolicyNote,
      };
    }
    return {
      'scope': 'member_pack',
      'max_chars': GroupMemberHistory.memberMaxChars,
      'content_source': 'message.content',
      'includes': [
        'recent_tail',
        'self_replies',
        'pinned_co_dispatch_sibling_replies',
        'pinned_mentioner_replies',
        'channel_compaction_summary',
        'omitted_store_uris',
      ],
      'excludes': historyPolicyExcludes,
      'note': _historyPolicyNote,
    };
  }

  /// Append machine-readable group context for peer relay (no ACP param).
  static String embedPeerContextBlock(Map<String, dynamic> groupContext) {
    if (groupContext.isEmpty) return '';
    final encoded = const JsonEncoder.withIndent('  ').convert(groupContext);
    return '\n\n【GROUP_CONTEXT】\n```json\n$encoded\n```';
  }
}
