import '../../services/group/group_management_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/session/dm_session_create_service.dart';
import '../chat_service.dart';

/// App-side handler for Hub `session_create_req`.
///
/// Hub engines cannot create App channels locally. The shepaw CLI shim POSTs
/// here (via Hub peer HTTP → this frame); we run the same services as the
/// in-process CLI and attach the switch card to the in-flight turn.
class SessionCreatePeerHandler {
  SessionCreatePeerHandler({
    LocalDatabaseService? db,
    DmSessionCreateService? dm,
    GroupManagementService? group,
    void Function(String channelId)? notifyChannelUpdate,
    bool Function(String channelId, Map<String, dynamic> metadata)?
        publishMetadata,
  })  : _db = db ?? LocalDatabaseService(),
        _dm = dm,
        _group = group,
        _notify = notifyChannelUpdate ?? ChatService().notifyChannelUpdate,
        _publishMetadata = publishMetadata;

  final LocalDatabaseService _db;
  final DmSessionCreateService? _dm;
  final GroupManagementService? _group;
  final void Function(String channelId) _notify;
  final bool Function(String channelId, Map<String, dynamic> metadata)?
      _publishMetadata;

  static const reqType = 'session_create_req';
  static const respType = 'session_create_resp';
  static const _tag = 'SessionCreatePeer';

  Future<Map<String, dynamic>> handle(Map<String, dynamic> data) async {
    final kind = (data['kind'] as String?)?.trim() ?? 'dm';
    final channelId = (data['channel_id'] as String?)?.trim() ?? '';
    final actorId = (data['agent_id'] as String?)?.trim() ?? '';
    if (channelId.isEmpty) {
      return {'error': 'Missing channel_id'};
    }
    if (actorId.isEmpty) {
      return {'error': 'Missing agent_id'};
    }
    final actorName = (data['agent_name'] as String?)?.trim().isNotEmpty == true
        ? (data['agent_name'] as String).trim()
        : actorId;

    final args = <String, dynamic>{
      if (data['reason'] != null) 'reason': data['reason'],
      if (data['reason_detail'] != null) 'reason_detail': data['reason_detail'],
      if (data['summary'] != null) 'summary': data['summary'],
      if (data['handoff'] is Map)
        'handoff': Map<String, dynamic>.from(data['handoff'] as Map),
      if (data['handoff_uri'] != null) 'handoff_uri': data['handoff_uri'],
      'post_first_message': data['post_first_message'] != false,
      'suggest_switch': data['suggest_switch'] != false,
    };

    final json = kind == 'group'
        ? await _createGroup(
            channelId: channelId,
            actorId: actorId,
            actorName: actorName,
            args: args,
          )
        : await _createDm(
            channelId: channelId,
            actorId: actorId,
            actorName: actorName,
            args: args,
          );

    final action = json['session_action'];
    if (action is Map && json['error'] == null) {
      await _attachSwitchCard(
        channelId: channelId,
        actorId: actorId,
        actorName: actorName,
        sessionAction: Map<String, dynamic>.from(action),
      );
    }
    return json;
  }

  Future<Map<String, dynamic>> _createDm({
    required String channelId,
    required String actorId,
    required String actorName,
    required Map<String, dynamic> args,
  }) async {
    final service = _dm ??
        DmSessionCreateService(
          db: _db,
          notifyChannelUpdate: _notify,
        );
    final result = await service.create(
      channelId: channelId,
      actorId: actorId,
      actorName: actorName,
      args: args,
    );
    return result.toCliJson();
  }

  Future<Map<String, dynamic>> _createGroup({
    required String channelId,
    required String actorId,
    required String actorName,
    required Map<String, dynamic> args,
  }) async {
    final service = _group ?? GroupManagementService();
    final result = await service.createSessionWithHandoff(
      channelId: channelId,
      actorId: actorId,
      actorName: actorName,
      args: args,
    );
    return result.toCliJson();
  }

  Future<void> _attachSwitchCard({
    required String channelId,
    required String actorId,
    required String actorName,
    required Map<String, dynamic> sessionAction,
  }) async {
    final published = _publishMetadata?.call(channelId, {
          DmSessionCreateService.metaActionKey: sessionAction,
        }) ??
        false;
    if (published) return;

    final id =
        'session_switch_${channelId.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
    try {
      await _db.createMessage(
        id: id,
        channelId: channelId,
        senderId: actorId,
        senderType: 'agent',
        senderName: actorName,
        content: 'New session ready. Open it to continue.',
        messageType: 'text',
        metadata: {
          DmSessionCreateService.metaActionKey: sessionAction,
        },
      );
      await _db.markMessageAsRead(id);
      _notify(channelId);
    } catch (e) {
      LoggerService().warning(
        'Failed to attach session switch card: $e',
        tag: _tag,
      );
    }
  }
}
