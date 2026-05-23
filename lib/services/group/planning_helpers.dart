import '../../models/planning_models.dart';
import '../local_database_service.dart';

/// Helpers for flow-mode message cleanup.
class PlanningHelpers {
  final LocalDatabaseService _db;
  final void Function(String channelId) notifyChannelUpdate;

  PlanningHelpers({
    required LocalDatabaseService db,
    required this.notifyChannelUpdate,
  }) : _db = db;

  /// Strip [FLOW_PLAN]...[/FLOW_PLAN] from the last Admin message.
  /// Returns the message ID of the stripped message, or null if not found.
  Future<String?> stripFlowPlanBlockFromLastMessage(String channelId, String agentId) async {
    final db = await _db.database;
    final results = await db.query(
      'messages',
      where: 'channel_id = ? AND sender_id = ?',
      whereArgs: [channelId, agentId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    final row = results.first;
    final msgId = row['id'] as String?;
    final rawContent = row['content'] as String? ?? '';
    final stripped = FlowPlan.stripFlowPlanBlock(rawContent);
    if (stripped != rawContent) {
      await _db.updateMessage(messageId: row['id'] as String, content: stripped);
    }
    return msgId;
  }
}
