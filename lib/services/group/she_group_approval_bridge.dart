import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../controllers/group_interaction_planner.dart';
import '../../models/message.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../she_service.dart';
import '../task/plan_approval_service.dart';
import '../approval/pending_approval_hub.dart';
import '../approval/pending_approval_item.dart';

/// Headless interaction + She-DM jump bridge for She-triggered group sends.
///
/// Approvals still live on the bound group session messages; this only:
/// 1. Persists interaction metadata when no ChatController is attached
/// 2. Injects a tappable notice into the triggering She↔user session
class SheGroupApprovalBridge {
  SheGroupApprovalBridge({
    LocalDatabaseService? db,
    ChatService? chatService,
    PlanApprovalService? planApprovals,
  })  : _db = db ?? LocalDatabaseService(),
        _chat = chatService ?? ChatService(),
        _planApprovals = planApprovals ?? PlanApprovalService.instance;

  final LocalDatabaseService _db;
  final ChatService _chat;
  final PlanApprovalService _planApprovals;
  static const _tag = 'SheGroupApprovalBridge';
  static const _uuid = Uuid();

  /// Metadata key on the She-DM system message (rendered as jump card).
  static const bridgeMetaKey = 'group_approval_bridge';

  Future<Map<String, dynamic>?> handleInteraction({
    required String sheChannelId,
    required String groupChannelId,
    required String groupName,
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
  }) async {
    final payload = Map<String, dynamic>.from(data);
    final explicitSavedId = GroupInteractionPlanner.takeSavedMessageId(payload);
    final isPeerAction = interactionType == 'action_confirmation' &&
        (payload['confirmation_context'] as String?) == 'peer';

    // Peer in-band approvals often fire before the turn message is persisted.
    // Never glue the card onto a stale prior agent bubble — create a dedicated
    // host so the bound group session always has a tappable review entry.
    String? savedMessageId = explicitSavedId;
    if (savedMessageId == null && isPeerAction) {
      savedMessageId = await _ensurePeerApprovalHostMessage(
        groupChannelId: groupChannelId,
        agentId: agentId,
        agentName: agentName,
        data: payload,
      );
    } else {
      savedMessageId ??= await _lastAgentMessageId(groupChannelId, agentId);
    }

    if (savedMessageId != null) {
      try {
        final row = await _db.getMessageById(savedMessageId);
        Map<String, dynamic>? existing;
        final raw = row?['metadata'];
        if (raw is String && raw.isNotEmpty) {
          try {
            existing = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          } catch (_) {}
        } else if (raw is Map) {
          existing = Map<String, dynamic>.from(raw);
        }
        await _db.updateMessageMetadata(
          savedMessageId,
          GroupInteractionPlanner.metadataForPersist(
            existing: existing,
            interactionType: interactionType,
            data: payload,
          ),
        );
      } catch (e) {
        LoggerService().warning(
          'Failed to persist $interactionType on $savedMessageId: $e',
          tag: _tag,
        );
      }
    }

    if (interactionType == 'plan_approval' && savedMessageId != null) {
      // Register so reattach works if the user opens the group session while
      // this process is still alive (same as UI path Completer registry).
      _planApprovals.awaitPlanApproval(
        channelId: groupChannelId,
        agentId: agentId,
        agentName: agentName,
        planData: payload,
        messageId: savedMessageId,
      );
    }

    final hubItem = PendingApprovalItem.fromInteraction(
      channelId: groupChannelId,
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: payload,
      messageId: savedMessageId,
    );
    if (hubItem != null) {
      PendingApprovalHub.instance.upsert(hubItem);
    }

    await injectBridgeNotice(
      sheChannelId: sheChannelId,
      groupChannelId: groupChannelId,
      groupName: groupName,
      interactionType: interactionType,
      agentName: agentName,
    );

    return GroupInteractionPlanner.nonBlockingResult();
  }

  /// Create a dedicated peer-approval host in the bound group when headless
  /// (no ChatController streaming bubble).
  Future<String> _ensurePeerApprovalHostMessage({
    required String groupChannelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> data,
  }) async {
    final confirmationId = data['confirmation_id'] as String? ?? '';
    // Stable id so hub reconnect / duplicate interaction callbacks update
    // the same card instead of stacking hosts.
    final id = confirmationId.isNotEmpty
        ? 'group_peer_approval_$confirmationId'
        : 'group_peer_approval_${agentId}_${DateTime.now().millisecondsSinceEpoch}';

    final existing = await _db.getMessageById(id);
    final prompt = (data['prompt'] as String?)?.trim();
    final content =
        (prompt != null && prompt.isNotEmpty) ? prompt : '需要您的确认';
    final metadata = GroupInteractionPlanner.metadataForPersist(
      existing: null,
      interactionType: 'action_confirmation',
      data: data,
    );

    if (existing != null) {
      await _db.updateMessageMetadata(id, metadata);
      return id;
    }

    await _db.createMessage(
      id: id,
      channelId: groupChannelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: agentName,
      content: content,
      messageType: 'text',
      metadata: metadata,
    );
    await _db.markMessageAsRead(id);
    _chat.notifyChannelUpdate(groupChannelId);
    LoggerService().info(
      'Created peer approval host $id in group $groupChannelId '
      'for $agentName ($confirmationId)',
      tag: _tag,
    );
    return id;
  }

  Future<void> injectBridgeNotice({
    required String sheChannelId,
    required String groupChannelId,
    required String groupName,
    required String interactionType,
    required String agentName,
  }) async {
    final label = _labelFor(interactionType);
    final msg = Message(
      id: _uuid.v4(),
      content: '群「$groupName」有待你审核的操作（$label），请前往绑定群会话处理。',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
      metadata: {
        bridgeMetaKey: {
          'group_channel_id': groupChannelId,
          'group_name': groupName,
          'interaction_type': interactionType,
          'agent_name': agentName,
          'status': 'pending',
        },
      },
    );
    await _chat.saveLocalMessage(
      msg,
      SheService.sheId,
      channelId: sheChannelId,
    );
    LoggerService().info(
      'Injected approval bridge into She session $sheChannelId '
      '→ group $groupChannelId ($interactionType)',
      tag: _tag,
    );
  }

  Future<String?> _lastAgentMessageId(String channelId, String agentId) async {
    final messages = await _chat.loadChannelMessages(channelId, limit: 30);
    for (final m in messages.reversed) {
      if (m.from.isAgent && m.from.id == agentId) return m.id;
    }
    return null;
  }

  static String _labelFor(String interactionType) {
    switch (interactionType) {
      case 'plan_approval':
        return '工作流计划审批';
      case 'action_confirmation':
        return '操作确认';
      case 'form':
        return '表单填写';
      case 'single_select':
      case 'multi_select':
        return '选项确认';
      case 'file_upload':
        return '文件上传';
      default:
        return interactionType;
    }
  }
}
