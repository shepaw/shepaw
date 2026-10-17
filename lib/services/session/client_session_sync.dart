import 'package:shared_preferences/shared_preferences.dart';

/// 主机会话列表里 ShePaw 自己的会话。这类会话权威在远端，始终同步。
const String kSessionOriginShepaw = 'shepaw';

/// Cursor IDE 里的会话。
const String kSessionOriginIde = 'ide';

/// Cursor CLI 终端里的会话。主机字段名是 `terminal`。
const String kSessionOriginTerminal = 'terminal';

/// 其他引擎目录里的外部会话。
const String kSessionOriginExternal = 'external';

/// 编辑页「同步客户端会话」开关。
///
/// 键名沿用旧的 `peer_sync_disabled_<agentId>`。以前它关掉整段远端同步；
/// 现在 ShePaw 会话始终同步，这个键只决定要不要把 agent 自己的客户端会话
/// （Cursor IDE / CLI 终端等）拉进会话列表。未设置视为开启，和开关默认一致。
const String kClientSessionSyncDisabledPrefsPrefix = 'peer_sync_disabled_';

/// 主机 `source` 不是 ShePaw、也不是空，就当作 agent 自己的客户端会话。
bool isAgentClientSessionSource(String? source) {
  final value = source?.trim() ?? '';
  return value.isNotEmpty && value != kSessionOriginShepaw;
}

Future<bool> isClientSessionSyncEnabled(String agentId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('$kClientSessionSyncDisabledPrefsPrefix$agentId') !=
      true;
}

Future<void> setClientSessionSyncEnabled(String agentId, bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(
    '$kClientSessionSyncDisabledPrefsPrefix$agentId',
    !enabled,
  );
}
