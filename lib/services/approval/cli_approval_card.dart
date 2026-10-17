import 'dart:convert';

import '../../clis/shepaw/os/os_executor.dart' as os_exec;
import '../../models/remote_agent.dart';
import '../cli_approval_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import 'cli_audit_fold.dart';
import 'pending_approval_hub.dart';
import 'pending_approval_item.dart';

/// 造一张 CLI / OS 审核卡并落进它**归属**的会话。
///
/// 归属会话当前不在屏幕上时走这里：卡片只写进那个频道的库里，再挂一条全局
/// 提醒（顶部横幅），用户点提醒跳回去作答。
///
/// 关键约束：**不会**把卡插进当前可见的会话。审核卡属于发起回合的频道，
/// 不属于用户此刻正在看的频道 —— 否则就会串台。
class CliApprovalCard {
  CliApprovalCard._();

  static const _tag = 'CliApproval';

  static String confirmationIdFor(String toolName) =>
      'cli_${DateTime.now().millisecondsSinceEpoch}_$toolName';

  static Map<String, dynamic> buildActionData({
    required String confirmationId,
    required String toolName,
    required Map<String, dynamic> flags,
    required os_exec.RiskLevel risk,
  }) =>
      {
        'confirmation_id': confirmationId,
        'confirmation_context': 'cli',
        'prompt': os_exec.getRiskDescription(risk, toolName, flags),
        'tool_name': toolName,
        'flags': Map<String, dynamic>.from(flags),
        'risk': risk.name,
        'actions': [
          {'id': 'deny', 'label': 'Deny', 'style': 'secondary'},
          {'id': 'allow', 'label': 'Allow', 'style': 'primary'},
        ],
      };

  /// 把卡写进 [channelId] 并提醒，然后等用户在那个会话里点。
  ///
  /// 等待期间本进程内一直挂着 Completer，用户什么时候跳回去点都算数。
  static Future<bool> awaitOffscreen({
    required String confirmationId,
    required String toolName,
    required Map<String, dynamic> flags,
    required os_exec.RiskLevel risk,
    required String channelId,
    required String agentId,
    String? agentName,
    LocalDatabaseService? db,
  }) async {
    final database = db ?? LocalDatabaseService();
    final actionData = buildActionData(
      confirmationId: confirmationId,
      toolName: toolName,
      flags: flags,
      risk: risk,
    );

    final name = agentName ?? await _resolveAgentName(database, agentId);
    final messageId = await _persistOffscreen(
      database: database,
      channelId: channelId,
      agentId: agentId,
      agentName: name,
      actionData: actionData,
    );

    final hubItem = PendingApprovalItem.fromInteraction(
      channelId: channelId,
      agentId: agentId,
      agentName: name,
      interactionType: 'action_confirmation',
      data: actionData,
      messageId: messageId,
    );
    if (hubItem != null) {
      PendingApprovalHub.instance.upsert(hubItem);
    }

    LoggerService().info(
      'CLI approval for $toolName parked in its own channel '
      '$channelId (not the visible one)',
      tag: _tag,
    );

    return CliApprovalService.instance.awaitApproval(
      confirmationId: confirmationId,
      toolName: toolName,
      channelId: channelId,
    );
  }

  /// 当前回合已有审计气泡就续写，否则新建一条。落库失败仍返回 id，调用方继续等。
  static Future<String> _persistOffscreen({
    required LocalDatabaseService database,
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> actionData,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var messageId = CliAuditFold.messageIdFor(agentId, nowMs);
    var metadata = CliAuditFold.attachPending(
      metadata: const {},
      actionData: actionData,
    )!;
    var reused = false;

    try {
      final rows = await database.getChannelMessages(channelId, limit: 40);
      for (final row in rows) {
        final senderType = row['sender_type'] as String? ?? '';
        if (senderType == 'user') break;
        if (row['sender_id'] != agentId) continue;
        final existing = _decodeMetadata(row['metadata']);
        if (!CliAuditFold.isHost(existing)) continue;
        final next = CliAuditFold.attachPending(
          metadata: existing,
          actionData: actionData,
        );
        if (next == null) break;
        messageId = row['id'] as String;
        metadata = next;
        reused = true;
        break;
      }
      if (reused) {
        await database.updateMessageMetadata(messageId, metadata);
        await database.touchMessageCreatedAt(messageId);
      } else {
        await database.createMessage(
          id: messageId,
          channelId: channelId,
          senderId: agentId,
          senderType: 'agent',
          senderName: agentName,
          content: '',
          messageType: 'text',
          metadata: metadata,
        );
      }
    } catch (e) {
      // 落库失败也要继续等：卡没了但用户还能从日志里看到，直接拒绝更糟。
      LoggerService().warning(
        'Failed to persist offscreen CLI approval card for '
        '$channelId: $e',
        tag: _tag,
      );
    }
    return messageId;
  }

  static Map<String, dynamic> _decodeMetadata(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  static Future<String> _resolveAgentName(
    LocalDatabaseService db,
    String agentId,
  ) async {
    if (agentId.isEmpty) return 'Agent';
    try {
      final RemoteAgent? agent = await db.getRemoteAgentById(agentId);
      final name = agent?.name.trim() ?? '';
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return agentId;
  }
}
