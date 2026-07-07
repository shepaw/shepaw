import '../models/remote_agent.dart';
import 'group/group_dispatch_parser.dart';
import 'local_database_service.dart';

/// Resolve a [RemoteAgent] by database id or registered display name.
class AgentResolver {
  const AgentResolver._();

  static Future<RemoteAgent?> byIdOrName(
    LocalDatabaseService db,
    String idOrName,
  ) async {
    final trimmed = idOrName.trim();
    if (trimmed.isEmpty) return null;

    final byId = await db.getRemoteAgentById(trimmed);
    if (byId != null) return byId;

    final all = await db.getAllRemoteAgents();
    return GroupDispatchParser.findAgentByDispatchName(all, trimmed);
  }
}
