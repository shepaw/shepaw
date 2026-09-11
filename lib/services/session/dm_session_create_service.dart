import '../../models/channel.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import '../group/group_session_handoff.dart';

/// Creates a new 1:1 DM session with a curated handoff summary.
///
/// Parallel to [GroupSessionCreateService]: does not auto-switch; the caller
/// attaches [sessionAction] to the current turn so the UI can show a switch
/// card. The agent must not assume the user already moved.
class DmSessionCreateService {
  DmSessionCreateService({
    LocalDatabaseService? db,
    void Function(String channelId)? notifyChannelUpdate,
  })  : _db = db ?? LocalDatabaseService(),
        _notify = notifyChannelUpdate ?? ChatService().notifyChannelUpdate;

  final LocalDatabaseService _db;
  final void Function(String channelId) _notify;
  static const _tag = 'DmSessionCreate';

  /// Metadata key written on the current-turn agent message.
  ///
  /// Also accepted by the switch card for group sessions
  /// ([GroupSessionHandoff.metaActionKey]).
  static const metaActionKey = 'session_action';

  static const validReasonCodes = {
    'topic_shift',
    'post_delivery',
    'noise_reduction',
    'context_too_long',
    'agent_memory_reset',
    'parallel_track',
    'user_requested',
  };

  Future<DmSessionCreateResult> create({
    required String channelId,
    required String actorId,
    required String actorName,
    required Map<String, dynamic> args,
    String userId = LocalUserIdentity.id,
  }) async {
    final channel = await _db.getChannelById(channelId);
    if (channel == null || !channel.isDM) {
      return DmSessionCreateResult.failure(
        'DM channel not found. Use `shepaw chat group session create` in a group.',
      );
    }
    if (channel.isGroupBoundMemberSession || channel.isSheBoundSession) {
      return DmSessionCreateResult.failure(
        'Bound relay sessions cannot be forked with chat session create',
      );
    }
    if (!channel.members.any((m) => m.id == actorId)) {
      return DmSessionCreateResult.failure(
        'Permission denied: agent is not a member of this session',
      );
    }

    final reason = args['reason']?.toString().trim() ?? '';
    if (reason.isEmpty || !validReasonCodes.contains(reason)) {
      return DmSessionCreateResult.failure(
        'reason must be one of: ${validReasonCodes.join(", ")}',
      );
    }
    final reasonDetail = args['reason_detail']?.toString().trim();
    final summary = _resolveSummary(args);
    if (summary == null || summary.isEmpty) {
      return DmSessionCreateResult.failure(
        'Provide --summary or handoff.task.user_goal',
      );
    }

    final postFirstMessage = args['post_first_message'] != false;
    final suggestSwitch = args['suggest_switch'] != false;

    final agentId = channel.agentIds.isNotEmpty
        ? channel.agentIds.first
        : actorId;
    final resolvedUserId = _resolveUserId(channel, actorId, userId);
    final agentName = await _resolveAgentName(agentId, actorId, actorName);

    final ids = [resolvedUserId, agentId]..sort();
    final newSessionId =
        'dm_${ids.join('_')}_${DateTime.now().millisecondsSinceEpoch}';

    final newChannel = Channel(
      id: newSessionId,
      name: channel.name,
      type: 'dm',
      members: [
        for (final m in channel.members)
          ChannelMember(
            id: m.id,
            type: m.type,
            role: m.role,
            joinedAt: DateTime.now().millisecondsSinceEpoch,
            groupBio: m.groupBio,
          ),
      ],
      isPrivate: true,
      description: channel.description,
    );
    try {
      await _db.createChannel(newChannel, resolvedUserId);
    } catch (e) {
      return DmSessionCreateResult.failure('Failed to create session: $e');
    }

    String? firstMessageId;
    if (postFirstMessage) {
      firstMessageId = await _postHandoffMessage(
        channelId: newSessionId,
        actorId: actorId,
        actorName: actorName,
        reason: reason,
        reasonDetail: reasonDetail,
        summary: summary,
        sourceSessionId: channelId,
      );
    }

    final sessionAction = {
      'type': 'switch',
      'new_session_id': newSessionId,
      'source_session_id': channelId,
      'reason': reason,
      if (reasonDetail != null && reasonDetail.isNotEmpty)
        'reason_detail': reasonDetail,
      'status': suggestSwitch ? 'pending' : 'created',
      if (firstMessageId != null) 'first_message_id': firstMessageId,
      'agent_name': agentName,
    };

    LoggerService().info(
      'Created DM session $newSessionId from $channelId (reason=$reason)',
      tag: _tag,
    );
    _notify(channelId);
    _notify(newSessionId);

    return DmSessionCreateResult.success(
      newSessionId: newSessionId,
      sourceSessionId: channelId,
      sessionAction: sessionAction,
    );
  }

  static String? _resolveSummary(Map<String, dynamic> args) {
    final direct = args['summary']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final handoff = args['handoff'];
    if (handoff is Map) {
      final task = handoff['task'];
      if (task is Map) {
        final goal = task['user_goal']?.toString().trim();
        if (goal != null && goal.isNotEmpty) return goal;
      }
    }
    return null;
  }

  static String _resolveUserId(
    Channel channel,
    String actorId,
    String fallback,
  ) {
    for (final m in channel.members) {
      if (m.id == LocalUserIdentity.id) return m.id;
    }
    for (final m in channel.members) {
      if (m.isUser && m.id != actorId) return m.id;
    }
    return fallback;
  }

  Future<String> _resolveAgentName(
    String agentId,
    String actorId,
    String actorName,
  ) async {
    if (agentId == actorId && actorName.isNotEmpty) return actorName;
    try {
      final agent = await _db.getRemoteAgentById(agentId);
      final name = agent?.name.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return actorName.isNotEmpty ? actorName : agentId;
  }

  Future<String> _postHandoffMessage({
    required String channelId,
    required String actorId,
    required String actorName,
    required String reason,
    required String? reasonDetail,
    required String summary,
    required String sourceSessionId,
  }) async {
    final id =
        'dm_handoff_${channelId.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
    final buf = StringBuffer()
      ..writeln('【会话交接】')
      ..writeln()
      ..writeln(summary.trim());
    if (reasonDetail != null && reasonDetail.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('原因：$reasonDetail');
    }
    buf
      ..writeln()
      ..writeln('（来自上一会话，reason=`$reason`）');

    await _db.createMessage(
      id: id,
      channelId: channelId,
      senderId: actorId,
      senderType: 'agent',
      senderName: actorName,
      content: buf.toString().trim(),
      messageType: 'text',
      metadata: {
        'session_handoff': {
          'reason': reason,
          if (reasonDetail != null && reasonDetail.isNotEmpty)
            'reason_detail': reasonDetail,
          'source_session_id': sourceSessionId,
        },
      },
    );
    await _db.markMessageAsRead(id);
    return id;
  }
}

class DmSessionCreateResult {
  const DmSessionCreateResult._({
    required this.ok,
    this.error,
    this.newSessionId,
    this.sourceSessionId,
    this.sessionAction,
  });

  final bool ok;
  final String? error;
  final String? newSessionId;
  final String? sourceSessionId;
  final Map<String, dynamic>? sessionAction;

  factory DmSessionCreateResult.success({
    required String newSessionId,
    required String sourceSessionId,
    required Map<String, dynamic> sessionAction,
  }) =>
      DmSessionCreateResult._(
        ok: true,
        newSessionId: newSessionId,
        sourceSessionId: sourceSessionId,
        sessionAction: sessionAction,
      );

  factory DmSessionCreateResult.failure(String error) =>
      DmSessionCreateResult._(ok: false, error: error);

  Map<String, dynamic> toCliJson() => ok
      ? {
          'status': 'ok',
          'new_session_id': newSessionId,
          'source_session_id': sourceSessionId,
          'session_action': sessionAction,
          'note':
              'New session created. Show the switch card; do not assume the user already switched. Continue in the new session only after they open it.',
        }
      : {'error': error};
}

/// Look up a session-switch payload on a message, whether written by the
/// group tool or the DM CLI.
Map<String, dynamic>? sessionSwitchActionOf(Map<String, dynamic>? metadata) {
  if (metadata == null) return null;
  final dm = metadata[DmSessionCreateService.metaActionKey];
  if (dm is Map) return Map<String, dynamic>.from(dm);
  final group = metadata[GroupSessionHandoff.metaActionKey];
  if (group is Map) return Map<String, dynamic>.from(group);
  return null;
}
