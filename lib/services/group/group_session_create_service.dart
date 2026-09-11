import 'dart:convert';

import '../../storage/group_workspace_service.dart';
import '../../storage/store_uri_reader.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import 'group_admin_gate.dart';
import 'group_session_handoff.dart';
import 'group_task_bootstrap.dart';

/// Creates a new group session with a curated handoff package.
class GroupSessionCreateService {
  GroupSessionCreateService({
    LocalDatabaseService? db,
    ChatService? chatService,
  })  : _db = db ?? LocalDatabaseService(),
        _chat = chatService ?? ChatService();

  final LocalDatabaseService _db;
  final ChatService _chat;
  static const _tag = 'GroupSessionCreate';

  Future<GroupSessionCreateResult> create({
    required String channelId,
    required String actorId,
    required String actorName,
    required Map<String, dynamic> args,
    String userId = LocalUserIdentity.id,
  }) async {
    final channel = await _db.getChannelById(channelId);
    final denied = GroupAdminGate.denyReason(
      channel: channel,
      channelId: channelId,
      actorId: actorId,
    );
    if (denied != null) {
      return GroupSessionCreateResult.failure(denied);
    }
    if (channel == null || !channel.isGroup) {
      return GroupSessionCreateResult.failure('Group channel not found');
    }

    final reason = args['reason']?.toString().trim() ??
        args['reason_code']?.toString().trim() ??
        '';
    final reasonDetail = args['reason_detail']?.toString().trim();
    final postFirstMessage = args['post_first_message'] != false;
    final suggestSwitch = args['suggest_switch'] != false;

    var inlineHandoff = args['handoff'];
    final handoffUri = args['handoff_uri']?.toString().trim();

    if (inlineHandoff is Map && reason.isNotEmpty) {
      final copy = Map<String, dynamic>.from(inlineHandoff);
      final nestedReason = copy['reason'];
      if (nestedReason is! Map ||
          nestedReason['code'] == null ||
          '${nestedReason['code']}'.trim().isEmpty) {
        copy['reason'] = {
          if (nestedReason is Map) ...Map<String, dynamic>.from(nestedReason),
          'code': reason,
          if (reasonDetail != null && reasonDetail.isNotEmpty)
            'detail': reasonDetail,
        };
      }
      inlineHandoff = copy;
    }

    String? handoffJsonText;
    if (handoffUri != null &&
        handoffUri.isNotEmpty &&
        (inlineHandoff == null ||
            (inlineHandoff is Map && inlineHandoff.isEmpty))) {
      try {
        final bytes = await StoreUriReader.instance.read(handoffUri);
        handoffJsonText = utf8.decode(bytes);
      } catch (e) {
        return GroupSessionCreateResult.failure(
          'Failed to read handoff_uri: $e',
        );
      }
    }

    final parsed = GroupSessionHandoff.parse(
      inlineHandoff: inlineHandoff is Map
          ? Map<String, dynamic>.from(inlineHandoff)
          : null,
      handoffUri: handoffUri,
      handoffJsonText: handoffJsonText,
      sourceSessionId: channelId,
      createdByAgentId: actorId,
      createdByAgentName: actorName,
    );
    if (parsed.error != null || parsed.handoff == null) {
      return GroupSessionCreateResult.failure(parsed.error ?? 'invalid handoff');
    }

    var handoff = parsed.handoff!;
    final familyId = channel.groupFamilyId;
    if ((handoff.orchestrationSummary == null ||
            handoff.orchestrationSummary!.trim().isEmpty) &&
        handoff.orchestrationId != null &&
        handoff.orchestrationId!.trim().isNotEmpty) {
      final excerpt = await GroupTaskBootstrap.archiveExcerpt(
        groupId: familyId,
        orchestrationId: handoff.orchestrationId!.trim(),
      );
      if (excerpt != null && excerpt.isNotEmpty) {
        handoff = GroupSessionHandoff(
          handoffId: handoff.handoffId,
          reasonCode: handoff.reasonCode,
          reasonDetail: handoff.reasonDetail,
          userGoal: handoff.userGoal,
          acceptanceCriteria: handoff.acceptanceCriteria,
          status: handoff.status,
          title: handoff.title,
          statusNote: handoff.statusNote,
          sourceSessionId: handoff.sourceSessionId ?? channelId,
          sourceSessionLabel: handoff.sourceSessionLabel,
          orchestrationId: handoff.orchestrationId,
          orchestrationSummary: excerpt,
          constraints: handoff.constraints,
          artifacts: handoff.artifacts,
          openItems: handoff.openItems,
          roles: handoff.roles,
          firstMessageDraft: handoff.firstMessageDraft,
          createdByAgentId: handoff.createdByAgentId,
          createdByAgentName: handoff.createdByAgentName,
          createdAt: handoff.createdAt,
        );
      }
    }
    if (reason.isNotEmpty && GroupSessionHandoff.validReasonCodes.contains(reason)) {
      handoff = GroupSessionHandoff(
        handoffId: handoff.handoffId,
        reasonCode: reason,
        reasonDetail: reasonDetail ?? handoff.reasonDetail,
        userGoal: handoff.userGoal,
        acceptanceCriteria: handoff.acceptanceCriteria,
        status: handoff.status,
        title: handoff.title,
        statusNote: handoff.statusNote,
        sourceSessionId: handoff.sourceSessionId ?? channelId,
        sourceSessionLabel: handoff.sourceSessionLabel,
        orchestrationId: handoff.orchestrationId,
        orchestrationSummary: handoff.orchestrationSummary,
        constraints: handoff.constraints,
        artifacts: handoff.artifacts,
        openItems: handoff.openItems,
        roles: handoff.roles,
        firstMessageDraft: handoff.firstMessageDraft,
        createdByAgentId: handoff.createdByAgentId,
        createdByAgentName: handoff.createdByAgentName,
        createdAt: handoff.createdAt,
      );
    } else if (reason.isNotEmpty &&
        !GroupSessionHandoff.validReasonCodes.contains(reason)) {
      return GroupSessionCreateResult.failure(
        'reason must be one of: '
        '${GroupSessionHandoff.validReasonCodes.join(", ")}',
      );
    }

    final jsonBody = jsonEncode(handoff.toJson());
    final provisionalMd = handoff.toMarkdown(jsonUri: '(pending)');
    final written = await GroupWorkspaceService.instance.writeSharedHandoff(
      groupId: familyId,
      handoffId: handoff.handoffId,
      jsonContent: jsonBody,
      markdownContent: provisionalMd,
    );
    if (written == null) {
      return GroupSessionCreateResult.failure(
        'Failed to write handoff to group workspace',
      );
    }

    final handoffJsonUri = written.jsonUri;
    final handoffMdUri = written.mdUri;
    final mdWithUri = handoff.toMarkdown(jsonUri: handoffJsonUri);
    await GroupWorkspaceService.instance.writeSharedHandoff(
      groupId: familyId,
      handoffId: handoff.handoffId,
      jsonContent: jsonBody,
      markdownContent: mdWithUri,
    );

    String newSessionId;
    try {
      newSessionId = await _chat.createNewGroupSession(
        channelId: channelId,
        userId: userId,
      );
    } catch (e) {
      return GroupSessionCreateResult.failure('Failed to create session: $e');
    }

    String? firstMessageId;
    if (postFirstMessage) {
      firstMessageId = await _postHandoffSystemMessage(
        channelId: newSessionId,
        handoff: handoff,
        handoffMdUri: handoffMdUri,
        handoffJsonUri: handoffJsonUri,
      );
    }

    final sessionAction = {
      'type': 'switch',
      'new_session_id': newSessionId,
      'source_session_id': channelId,
      'group_name': channel.name,
      'handoff_uri': handoffMdUri,
      'handoff_json_uri': handoffJsonUri,
      'handoff_id': handoff.handoffId,
      'reason': handoff.reasonCode,
      if (handoff.reasonDetail != null) 'reason_detail': handoff.reasonDetail,
      'status': suggestSwitch ? 'pending' : 'created',
      if (firstMessageId != null) 'first_message_id': firstMessageId,
    };

    LoggerService().info(
      'Created group session $newSessionId from $channelId '
      '(handoff=${handoff.handoffId})',
      tag: _tag,
    );

    return GroupSessionCreateResult.success(
      newSessionId: newSessionId,
      sourceSessionId: channelId,
      handoffId: handoff.handoffId,
      handoffUri: handoffMdUri,
      handoffJsonUri: handoffJsonUri,
      sessionAction: sessionAction,
    );
  }

  Future<String> _postHandoffSystemMessage({
    required String channelId,
    required GroupSessionHandoff handoff,
    required String handoffMdUri,
    required String handoffJsonUri,
  }) async {
    final id = 'group_handoff_${handoff.handoffId}';
    final content = handoff.formatFirstMessage(handoffUri: handoffMdUri);
    final existing = await _db.getMessageById(id);
    final metadata = {
      'group_handoff': {
        'handoff_id': handoff.handoffId,
        'handoff_uri': handoffMdUri,
        'handoff_json_uri': handoffJsonUri,
        'source_session_id': handoff.sourceSessionId,
      },
    };
    if (existing != null) {
      await _db.updateMessageMetadata(id, metadata);
      return id;
    }
    await _db.createMessage(
      id: id,
      channelId: channelId,
      senderId: 'system',
      senderType: 'system',
      senderName: 'System',
      content: content,
      messageType: 'system',
      metadata: metadata,
    );
    await _db.markMessageAsRead(id);
    _chat.notifyChannelUpdate(channelId);
    return id;
  }
}

class GroupSessionCreateResult {
  const GroupSessionCreateResult._({
    required this.ok,
    this.error,
    this.newSessionId,
    this.sourceSessionId,
    this.handoffId,
    this.handoffUri,
    this.handoffJsonUri,
    this.sessionAction,
  });

  final bool ok;
  final String? error;
  final String? newSessionId;
  final String? sourceSessionId;
  final String? handoffId;
  final String? handoffUri;
  final String? handoffJsonUri;
  final Map<String, dynamic>? sessionAction;

  factory GroupSessionCreateResult.success({
    required String newSessionId,
    required String sourceSessionId,
    required String handoffId,
    required String handoffUri,
    required String handoffJsonUri,
    required Map<String, dynamic> sessionAction,
  }) =>
      GroupSessionCreateResult._(
        ok: true,
        newSessionId: newSessionId,
        sourceSessionId: sourceSessionId,
        handoffId: handoffId,
        handoffUri: handoffUri,
        handoffJsonUri: handoffJsonUri,
        sessionAction: sessionAction,
      );

  factory GroupSessionCreateResult.failure(String error) =>
      GroupSessionCreateResult._(ok: false, error: error);

  Map<String, dynamic> toToolJson() => ok
      ? {
          'ok': true,
          'new_session_id': newSessionId,
          'source_session_id': sourceSessionId,
          'handoff_id': handoffId,
          'handoff_uri': handoffUri,
          'handoff_json_uri': handoffJsonUri,
        }
      : {'ok': false, 'error': error};

  Map<String, dynamic> toCliJson() => ok
      ? {
          'status': 'ok',
          'new_session_id': newSessionId,
          'source_session_id': sourceSessionId,
          'handoff_id': handoffId,
          'handoff_uri': handoffUri,
          'handoff_json_uri': handoffJsonUri,
          'session_action': sessionAction,
        }
      : {
          'error': error,
          if (error != null && error!.contains('Permission denied'))
            'permission_denied': true,
        };
}
