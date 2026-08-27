import 'dart:convert';

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

  /// L13: 同一消息上的 metadata read-modify-write 串行化。并发 handleInteraction
  /// 对同一气泡分别读-改-写会互相覆盖（丢失前一个交互的 key）——用 per-message
  /// future 链把读+合并+写压成原子序列，后到者基于最新已提交状态合并。
  final Map<String, Future<void>> _metadataTail = {};

  /// Metadata key on the She-DM system message (rendered as jump card).
  static const bridgeMetaKey = 'group_approval_bridge';

  /// Persist an approval/interaction onto the group session without a live
  /// [ChatController]: attach card metadata, register plan-approval reattach,
  /// and upsert [PendingApprovalHub]. Used by scheduled group tasks.
  ///
  /// Does **not** inject a She-DM jump notice — see [handleInteraction].
  Future<Map<String, dynamic>?> persistHeadlessInteraction({
    required String groupChannelId,
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
      // L13: 读-改-写压进 per-message 串行链，避免并发交互互相覆盖。
      await _mergeMessageMetadataSerialized(
        savedMessageId,
        (existing) => GroupInteractionPlanner.metadataForPersist(
          existing: existing,
          interactionType: interactionType,
          data: payload,
        ),
      );
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

    return GroupInteractionPlanner.nonBlockingResult();
  }

  Future<Map<String, dynamic>?> handleInteraction({
    required String sheChannelId,
    required String groupChannelId,
    required String groupName,
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
  }) async {
    final result = await persistHeadlessInteraction(
      groupChannelId: groupChannelId,
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
    );
    await injectBridgeNotice(
      sheChannelId: sheChannelId,
      groupChannelId: groupChannelId,
      groupName: groupName,
      interactionType: interactionType,
      agentName: agentName,
      data: data,
    );
    return result;
  }

  /// Per-message 串行的 metadata read-modify-write（L13）。
  ///
  /// [merge] 在链内基于「最新已提交」的 metadata 计算新值，再落库；同一消息
  /// 的并发调用按到达顺序排队，前一个写完成前不读 DB。
  Future<void> _mergeMessageMetadataSerialized(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>? existing) merge,
  ) {
    final prev = _metadataTail[messageId] ?? Future.value();
    final next = prev
        .catchError((Object _) {})
        .then((_) async {
          try {
            final row = await _db.getMessageById(messageId);
            Map<String, dynamic>? existing;
            final raw = row?['metadata'];
            if (raw is String && raw.isNotEmpty) {
              try {
                existing = Map<String, dynamic>.from(jsonDecode(raw) as Map);
              } catch (_) {}
            } else if (raw is Map) {
              existing = Map<String, dynamic>.from(raw);
            }
            await _db.updateMessageMetadata(messageId, merge(existing));
          } catch (e) {
            LoggerService().warning(
              'Failed to persist interaction metadata on $messageId: $e',
              tag: _tag,
            );
          }
        });
    // 链尾吞错，避免后续调用被前一个失败连带卡住。
    _metadataTail[messageId] = next.catchError((Object _) {});
    return next;
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
    Map<String, dynamic>? data,
  }) async {
    final label = _labelFor(interactionType);
    final id = _bridgeNoticeId(
      groupChannelId: groupChannelId,
      interactionType: interactionType,
      agentName: agentName,
      data: data,
    );
    final bridgeMeta = {
      'group_channel_id': groupChannelId,
      'group_name': groupName,
      'interaction_type': interactionType,
      'agent_name': agentName,
      'status': 'pending',
    };
    final existing = await _db.getMessageById(id);
    if (existing != null) {
      // M13b: 同一审批的重复回调（重连/幂等重放）只更新已有通知卡，
      // 不再向 She DM 堆叠第二条「待审核」系统消息。
      final raw = existing['metadata'];
      Map<String, dynamic>? meta;
      if (raw is String && raw.isNotEmpty) {
        try {
          meta = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } catch (_) {}
      } else if (raw is Map) {
        meta = Map<String, dynamic>.from(raw);
      }
      meta ??= <String, dynamic>{};
      meta[bridgeMetaKey] = bridgeMeta;
      await _db.updateMessageMetadata(id, meta);
      return;
    }
    final msg = Message(
      id: id,
      content: '群「$groupName」有待你审核的操作（$label），请前往绑定群会话处理。',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
      metadata: {bridgeMetaKey: bridgeMeta},
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

  /// 幂等通知 id：同一审批（同群 + 类型 + 审批 id）的重复回调定位同一张卡。
  /// 优先用载荷里的 confirmation_id / select_id / 通用 id / 工作流 id；
  /// 无稳定 id 时按 (群, 类型, agent) 折叠，避免重复通知堆叠。
  static String _bridgeNoticeId({
    required String groupChannelId,
    required String interactionType,
    required String agentName,
    Map<String, dynamic>? data,
  }) {
    final stable = (data?['confirmation_id'] as String?) ??
        (data?['select_id'] as String?) ??
        (data?['id'] as String?) ??
        (data?['_workflowId'] as String?);
    if (stable != null && stable.isNotEmpty) {
      return 'bridge_${groupChannelId}_${interactionType}_$stable';
    }
    return 'bridge_${groupChannelId}_${interactionType}_$agentName';
  }

  /// 最近 30 条消息里该 agent 最新一条的 id（审批卡片挂靠的气泡）。
  ///
  /// 注意：`loadChannelMessages` 内部经 `_mapsToMessages` 重排为升序
  /// （旧→新），因此 `messages.reversed` 恰好是新的在前——第一个命中即
  /// 最新一条。不要按 DAO 的 `created_at DESC` 反向“修正”这里的顺序。
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
