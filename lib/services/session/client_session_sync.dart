import 'package:shared_preferences/shared_preferences.dart';

/// 主机会话列表里 ShePaw 自己的会话。这类会话权威在远端，始终同步。
const String kSessionOriginShepaw = 'shepaw';

/// 官方 IDE 里的会话。目前只有 Cursor 会和终端分开标。
const String kSessionOriginIde = 'ide';

/// 官方终端里的会话。主机字段名是 `terminal`。
const String kSessionOriginTerminal = 'terminal';

/// 引擎自己的会话，但主机没有再分成 IDE / 终端。
const String kSessionOriginExternal = 'external';

/// 编辑页「同步客户端会话」开关在本机的缓存。
///
/// 权威在主机：`files/<agent>/client_sessions_sync.txt`。这里只记住主机
/// 最近一次告诉这台客户端的值，好让详情页在下一帧到来之前就能画出来。
/// 未设置视为开启，和主机缺省一致。ShePaw 自己的会话始终同步。
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

Future<bool> isClientSessionSyncEnabled(
  String agentId, {
  String? remoteAgentId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  for (final id in [agentId, if (remoteAgentId != null) remoteAgentId]) {
    if (id.isEmpty) continue;
    final key = '$kClientSessionSyncDisabledPrefsPrefix$id';
    if (prefs.containsKey(key)) return prefs.getBool(key) != true;
  }
  return true;
}

/// 记下主机上的开关。本机 id 和远端 id 各写一份，详情页用哪个都能读到。
Future<void> rememberClientSessionSync({
  required String localAgentId,
  required String remoteAgentId,
  required bool enabled,
}) async {
  final prefs = await SharedPreferences.getInstance();
  for (final id in {localAgentId, remoteAgentId}) {
    if (id.isEmpty) continue;
    await prefs.setBool('$kClientSessionSyncDisabledPrefsPrefix$id', !enabled);
  }
}

