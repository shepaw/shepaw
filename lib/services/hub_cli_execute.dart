import 'dart:convert';

import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../storage/runtime_paths.dart';
import 'cli_execution_gate.dart';
import 'local_database_service.dart';

/// Bound ACP `hub.cli.execute` — identity comes from the authenticated
/// session, never from caller-supplied `agent_id` / `owner` / `channel_id`.
class HubCliExecute {
  HubCliExecute({LocalDatabaseService? database})
      : _db = database ?? LocalDatabaseService();

  final LocalDatabaseService _db;

  /// In-flight group / DM session for an agent (group channel preferred).
  /// [ChatService] registers this so a omitted `session_id` still lands
  /// group writes in the group bag instead of personal runtime.
  static String? Function(String agentId)? activeSessionLookup;

  static const ignoredIdentityFlags = {
    'agent_id',
    'owner',
    'channel_id',
    'channel',
  };

  /// Strip forged identity fields. Store write already ignores them; this
  /// keeps them out of confirmation UI and logs as well.
  static Map<String, dynamic> sanitizeFlags(Object? raw) {
    final flags = <String, dynamic>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        final k = key.toString();
        if (ignoredIdentityFlags.contains(k)) return;
        flags[k] = value;
      });
    }
    return flags;
  }

  /// Only the App-issued `session_id` from `agent.chat` is a channel binding.
  /// Free-form `channel_id` is ignored.
  static String? boundSessionId(Map<String, dynamic>? params) {
    final s = (params?['session_id'] as String?)?.trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  /// Prefer the caller-supplied `session_id`; if omitted, use the in-flight
  /// turn (group channel or DM) so store writes do not fall into personal
  /// runtime during a group turn.
  static String? resolveSessionId(
    Map<String, dynamic>? params, {
    String? activeFallback,
  }) {
    final requested = boundSessionId(params);
    if (requested != null) return requested;
    final fallback = activeFallback?.trim();
    if (fallback == null || fallback.isEmpty) return null;
    return fallback;
  }

  static bool isMember(Channel channel, String agentId) =>
      channel.memberIds.contains(agentId);

  /// Extra allowlist for an authenticated session, or null when unrestricted.
  ///
  /// Remote ACP group members must be narrowed to the same surface as local
  /// ones ([kGroupMemberCliAllowlist]). Without this, the same non-admin
  /// member got `{store, help}` when running locally but every command its own
  /// `enabled_cli_commands` allowed when running remotely — and that allowlist
  /// is unrestricted by default, so `os.command.exec` went through.
  ///
  /// Same rule the group executor uses to build the schema
  /// (`group_agent_executor.dart`: `isAdmin ? null : kGroupMemberCliAllowlist`),
  /// so "the model was told it may call it" and "execution allows it" agree.
  static Set<String>? extraAllowlistFor(Channel? channel, String agentId) {
    if (channel == null || !channel.isGroup) return null;
    if (channel.isAdmin(agentId)) return null;
    return kGroupMemberCliAllowlist;
  }

  /// Map a member-verified channel to Gate `channelId` / `runtimeOwnerId`.
  /// Group-bound member DMs write into the group bag, not personal runtime.
  static ({String channelId, String runtimeOwnerId}) scopeOf(
    Channel channel,
    String agentId,
  ) {
    final target = RuntimePaths.resolveStoreTarget(
      agentId: agentId,
      channelId: channel.id,
      channelType: channel.type,
      parentGroupId: channel.parentGroupId,
      sourceGroupChannelId: channel.sourceGroupChannelId,
    );
    final src = channel.sourceGroupChannelId?.trim();
    if (src != null && src.isNotEmpty) {
      return (channelId: src, runtimeOwnerId: target.ownerId);
    }
    return (channelId: channel.id, runtimeOwnerId: target.ownerId);
  }

  /// Contract embedded in `group_context` for remote ACP agents.
  static Map<String, dynamic> groupContextHint() => {
        'method': 'hub.cli.execute',
        'note':
            'You have no shepaw function tool. Run shepaw CLI on the user '
            'device via hub.cli.execute. Identity is the authenticated ACP '
            'session — do not send agent_id, owner, or channel_id. Pass '
            'session_id from agent.chat (App fills the in-flight group/DM '
            'turn if omitted). This is ACP only; Agent Hub engines use '
            'the PATH shepaw shim (local store / App-forwarded CLI), '
            'not this method.',
        'params': {
          'namespace': 'store',
          'subcommand': 'write',
          'flags': <String, dynamic>{},
          'session_id': '<agent.chat session_id>',
        },
      };

  Future<String> execute({
    required String agentId,
    required RemoteAgent agent,
    required Map<String, dynamic> args,
    String? channelId,
    String? runtimeOwnerId,
    Set<String>? extraAllowlist,
  }) {
    return CliExecutionGate.instance.execute(
      args: args,
      agentId: agentId,
      channelId: channelId,
      runtimeOwnerId: runtimeOwnerId,
      enabledCliCommands: agent.enabledCliCommands,
      extraAllowlist: extraAllowlist,
      requireApproval: agent.cliRequireApproval,
    );
  }

  /// Resolve optional `session_id` and run the gate.
  ///
  /// Returns a JSON object (`ok` / `error` / CLI payload).
  Future<Map<String, dynamic>> run({
    required String agentId,
    Map<String, dynamic>? params,
  }) async {
    final namespace = (params?['namespace'] as String?)?.trim() ?? '';
    final subcommand = (params?['subcommand'] as String?)?.trim() ?? '';
    if (namespace.isEmpty) {
      return {
        'ok': false,
        'error': 'missing namespace',
      };
    }

    final agent = await _db.getRemoteAgentById(agentId);
    if (agent == null) {
      return {
        'ok': false,
        'error': 'unknown agent',
      };
    }

    String? channelId;
    String? runtimeOwnerId;
    // No bound session = not a group context → keep it unrestricted.
    Set<String>? extraAllowlist;
    final sessionId = resolveSessionId(
      params,
      activeFallback: activeSessionLookup?.call(agentId),
    );
    if (sessionId != null) {
      final channel = await _db.getChannelById(sessionId);
      if (channel == null || !isMember(channel, agentId)) {
        return {
          'ok': false,
          'error': 'session_id is not a bound session for this agent',
        };
      }
      extraAllowlist = extraAllowlistFor(channel, agentId);
      final scope = scopeOf(channel, agentId);
      channelId = scope.channelId;
      runtimeOwnerId = scope.runtimeOwnerId;
    }

    final raw = await execute(
      agentId: agentId,
      agent: agent,
      args: {
        'namespace': namespace,
        'subcommand': subcommand,
        'flags': sanitizeFlags(params?['flags']),
      },
      channelId: channelId,
      runtimeOwnerId: runtimeOwnerId,
      extraAllowlist: extraAllowlist,
    );

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        if (decoded['error'] != null && decoded['ok'] != true) {
          return {
            'ok': false,
            ...decoded,
          };
        }
        return {
          'ok': decoded['success'] == true || decoded['error'] == null,
          ...decoded,
        };
      }
    } catch (_) {}
    return {'ok': true, 'result': raw};
  }
}
