import 'package:shared_preferences/shared_preferences.dart';

/// 主机会话列表里 ShePaw 自己的会话。这类会话权威在远端，始终同步。
const String kSessionOriginShepaw = 'shepaw';

/// 官方 IDE 里的会话。目前只有 Cursor 会和终端分开标。
const String kSessionOriginIde = 'ide';

/// 官方终端里的会话。主机字段名是 `terminal`。
const String kSessionOriginTerminal = 'terminal';

/// 引擎自己的会话，但主机没有再分成 IDE / 终端。
const String kSessionOriginExternal = 'external';

/// 编辑页「同步客户端会话」开关。
///
/// 键名沿用旧的 `peer_sync_disabled_<agentId>`。以前它关掉整段远端同步；
/// 现在 ShePaw 会话始终同步，这个键只决定要不要把这个 agent 自己的官方终端
/// 或 IDE 会话拉进会话列表。未设置视为开启，和开关默认一致。
const String kClientSessionSyncDisabledPrefsPrefix = 'peer_sync_disabled_';

/// 主机 `source` 不是 ShePaw、也不是空，就当作 agent 自己的客户端会话。
bool isAgentClientSessionSource(String? source) {
  final value = source?.trim() ?? '';
  return value.isNotEmpty && value != kSessionOriginShepaw;
}

/// 落库用的来源。带上引擎，避免每个 agent 的标签都长得像 Cursor。
///
/// `cursor:ide`、`cursor:terminal`、`claude-code:external`。没有引擎时只留表面。
String? clientSessionStoreOrigin({String? engine, required String? source}) {
  if (!isAgentClientSessionSource(source)) return null;
  final surface = source!.trim();
  final id = engine?.trim() ?? '';
  if (id.isEmpty) return surface;
  return '$id:$surface';
}

/// 从落库值里拆出引擎和表面。旧数据只有 `ide` / `terminal` / `external`。
({String engine, String surface}) parseClientSessionOrigin(String stored) {
  final raw = stored.trim();
  final colon = raw.lastIndexOf(':');
  if (colon <= 0 || colon == raw.length - 1) {
    return (engine: '', surface: raw);
  }
  return (
    engine: raw.substring(0, colon),
    surface: raw.substring(colon + 1),
  );
}

/// 会话列表上的来源标签。Cursor 区分 IDE 和终端，其他引擎用自己的名字。
String clientSessionOriginLabel(
  String stored, {
  required String ide,
  required String cli,
}) {
  final parsed = parseClientSessionOrigin(stored);
  final name = officialClientName(parsed.engine);
  switch (parsed.surface) {
    case kSessionOriginIde:
      return name.isEmpty ? ide : '$name $ide';
    case kSessionOriginTerminal:
      return name.isEmpty ? cli : '$name $cli';
    default:
      return name.isEmpty ? parsed.surface : name;
  }
}

/// 引擎 id 对应的官方客户端名字。未知引擎就用 id 本身，避免标成别家的产品。
String officialClientName(String engine) {
  switch (engine.trim()) {
    case 'cursor':
      return 'Cursor';
    case 'claude-code':
    case 'tclaude':
    case 'claude-internal':
      return 'Claude Code';
    case 'codex':
    case 'tcodex':
      return 'Codex';
    case 'opencode':
      return 'OpenCode';
    case 'openclaw':
      return 'OpenClaw';
    case 'codebuddy':
      return 'CodeBuddy';
    case 'hermes':
      return 'Hermes';
    case 'copilot':
      return 'Copilot';
    case 'gemini':
    case 'gemini-internal':
      return 'Gemini';
    case 'qwen-code':
      return 'Qwen';
    case 'kimi':
      return 'Kimi';
    case 'kiro':
      return 'Kiro';
    case 'deepseek-harness':
      return 'DeepSeek';
    case 'pi':
      return 'Pi';
    case 'knot':
      return 'Knot';
    case 'zcode':
      return 'Zcode';
    default:
      return engine.trim();
  }
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
