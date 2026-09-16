import '../../models/acp_protocol.dart';
import '../../models/remote_agent.dart';
import '../acp_agent_connection.dart';
import '../logger_service.dart';

/// Live probe snapshot for one member before [group_dispatch] delegation.
class MemberCapabilitySnapshot {
  const MemberCapabilitySnapshot({
    required this.reachable,
    this.storeCliAvailable,
    this.notes = const [],
  });

  /// Agent / tunnel reachable at dispatch time.
  final bool reachable;

  /// `true`/`false` when probed; `null` when not applicable or inconclusive.
  final bool? storeCliAvailable;

  /// Human-readable probe notes for delivery hints / results.json.
  final List<String> notes;

  Map<String, dynamic> toDeliveryExtras() => {
        'reachable': reachable,
        if (storeCliAvailable != null) 'store_cli_live': storeCliAvailable,
        if (notes.isNotEmpty) 'probe_notes': notes,
      };
}

/// Preflight member capability checks before group dispatch.
///
/// Combines connectivity ([RemoteAgentService.checkAgentHealth]), Hub peer
/// runtime metadata, and a best-effort `hub.cli.execute store list` when an
/// ACP connection is already warm.
typedef MemberHealthCheck = Future<bool> Function(
  String agentId, {
  Duration timeout,
});

class GroupMemberCapabilityProbe {
  GroupMemberCapabilityProbe({
    required MemberHealthCheck checkHealth,
    ACPAgentConnection? Function(String agentId)? connectionLookup,
    Duration healthTimeout = const Duration(seconds: 3),
    Duration storeCliTimeout = const Duration(seconds: 3),
  })  : _checkHealth = checkHealth,
        _connectionLookup = connectionLookup,
        _healthTimeout = healthTimeout,
        _storeCliTimeout = storeCliTimeout;

  final MemberHealthCheck _checkHealth;
  final ACPAgentConnection? Function(String agentId)? _connectionLookup;
  final Duration _healthTimeout;
  final Duration _storeCliTimeout;

  static const _tag = 'GroupMemberProbe';

  Future<Map<String, MemberCapabilitySnapshot>> probeAll(
    Iterable<RemoteAgent> agents,
  ) async {
    final unique = <String, RemoteAgent>{for (final a in agents) a.id: a};
    final entries = await Future.wait(
      unique.values.map((a) async => MapEntry(a.id, await probe(a))),
    );
    return Map.fromEntries(entries);
  }

  Future<MemberCapabilitySnapshot> probe(RemoteAgent agent) async {
    if (agent.isLocal) {
      return const MemberCapabilitySnapshot(
        reachable: true,
        storeCliAvailable: true,
        notes: ['本地 LLM：shepaw store 工具可用'],
      );
    }

    final notes = <String>[];
    var reachable = false;
    try {
      reachable = await _checkHealth(agent.id, timeout: _healthTimeout);
    } catch (e) {
      LoggerService().debug(
        'Health probe failed for ${agent.name}: $e',
        tag: _tag,
      );
    }
    if (!reachable) {
      notes.add('派发前探测：成员不可达（离线或隧道未就绪）');
      return MemberCapabilitySnapshot(
        reachable: false,
        storeCliAvailable: false,
        notes: notes,
      );
    }

    if (agent.isPeerAgent) {
      final running = agent.peerAgentRunning;
      if (!running) {
        notes.add('Hub 实例未运行（metadata.running=false）');
      }
      return MemberCapabilitySnapshot(
        reachable: true,
        storeCliAvailable: running ? null : false,
        notes: notes,
      );
    }

    if (agent.usesHubCliExecute) {
      final cliOk = await _probeStoreCli(agent);
      if (cliOk == false) {
        notes.add('hub.cli.execute 探测失败：改用 workspace 挂载路径交付');
      } else if (cliOk == true) {
        notes.add('hub.cli.execute 可用');
      }
      return MemberCapabilitySnapshot(
        reachable: true,
        storeCliAvailable: cliOk,
        notes: notes,
      );
    }

    return MemberCapabilitySnapshot(reachable: true, notes: notes);
  }

  Future<bool?> _probeStoreCli(RemoteAgent agent) async {
    final lookup = _connectionLookup;
    if (lookup == null) return null;
    final conn = lookup(agent.id);
    if (conn == null || !conn.isConnected) return null;
    try {
      final resp = await conn
          .sendRequest(
            ACPMethod.hubExecuteCli,
            params: {
              'namespace': 'store',
              'subcommand': 'list',
              'flags': <String, dynamic>{},
            },
          )
          .timeout(_storeCliTimeout);
      return resp.isSuccess;
    } catch (e) {
      LoggerService().debug(
        'store CLI probe failed for ${agent.name}: $e',
        tag: _tag,
      );
      return false;
    }
  }
}
