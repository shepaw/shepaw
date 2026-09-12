import '../../models/remote_agent.dart';
import '../../services/hub_cli_execute.dart';
import '../../services/local_database_service.dart';

/// App-side handler for Hub `cli_execute_req`.
///
/// Hub engines type `shepaw …` on the computer. Store hits that belong to
/// the Hub device stay there; everything else (including another device's
/// pouch) is posted here so [CliExecutionGate] / she-only / allowlist decide.
///
/// Identity is the Hub engine row ([RemoteAgent.usesHubStoreCli]). Caller
/// `agent_id` / `owner` / `channel_id` flags are stripped — same contract as
/// ACP [HubCliExecute].
class PeerCliExecuteHandler {
  PeerCliExecuteHandler({
    LocalDatabaseService? db,
    Future<RemoteAgent?> Function(String id)? lookupAgent,
    Future<Map<String, dynamic>> Function({
      required String agentId,
      Map<String, dynamic>? params,
    })? run,
  })  : _db = db ?? LocalDatabaseService(),
        _lookupAgent = lookupAgent,
        _run = run;

  final LocalDatabaseService _db;
  final Future<RemoteAgent?> Function(String id)? _lookupAgent;
  final Future<Map<String, dynamic>> Function({
    required String agentId,
    Map<String, dynamic>? params,
  })? _run;

  static const reqType = 'cli_execute_req';
  static const respType = 'cli_execute_resp';

  Future<RemoteAgent?> _agent(String id) =>
      _lookupAgent?.call(id) ?? _db.getRemoteAgentById(id);

  Future<Map<String, dynamic>> handle(Map<String, dynamic> data) async {
    final agentId = (data['agent_id'] as String?)?.trim() ?? '';
    if (agentId.isEmpty) {
      return {'ok': false, 'error': 'missing agent_id'};
    }

    final agent = await _agent(agentId);
    if (agent == null) {
      return {'ok': false, 'error': 'unknown agent'};
    }
    if (!agent.usesHubStoreCli) {
      return {'ok': false, 'error': 'agent is not a Hub engine'};
    }

    final namespace = (data['namespace'] as String?)?.trim() ?? '';
    final subcommand = (data['subcommand'] as String?)?.trim() ?? '';
    if (namespace.isEmpty) {
      return {'ok': false, 'error': 'missing namespace'};
    }

    final run = _run ??
        ({
          required String agentId,
          Map<String, dynamic>? params,
        }) =>
            HubCliExecute(database: _db).run(
              agentId: agentId,
              params: params,
            );

    return run(
      agentId: agentId,
      params: {
        'namespace': namespace,
        'subcommand': subcommand,
        'flags': data['flags'],
        if (data['session_id'] != null) 'session_id': data['session_id'],
      },
    );
  }
}
