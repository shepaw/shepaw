// 引擎图标直接用打包进来的 SVG。文件从 agent-bridge 的
// `agent-hub/core/assets/engines/` 原样复制，和 shepaw-cli 用的是同一套。

/// 通用占位头像（无引擎图 / 未知引擎时的回退）。
const String kGenericDefaultAvatar = '🤖';

const String _kEngineAssetPrefix = 'assets/images/engines/';

/// Hub 下发的逻辑标记（真实图在同条消息的 `avatar_data`）。
const String _kEngineAvatarMarkerPrefix = 'engine-avatar:';

const Set<String> _bundledEngineIds = {
  'claude-code',
  'claude-internal',
  'codebuddy',
  'codex',
  'copilot',
  'cursor',
  'deepseek-harness',
  'gemini',
  'gemini-internal',
  'hermes',
  'kimi',
  'kiro',
  'knot',
  'opencode',
  'openclaw',
  'pi',
  'qwen-code',
  'tclaude',
  'tcodex',
  'zcode',
};

/// 有内置图标时返回 asset 路径，否则是表情占位。
String defaultAvatarForEngine(String? engineId) {
  final id = engineId?.trim() ?? '';
  if (!_bundledEngineIds.contains(id)) return kGenericDefaultAvatar;
  return '$_kEngineAssetPrefix$id.svg';
}

/// 是否为「尚未个性化」的占位头像（可被对端同步覆盖）。
bool isGenericDefaultAvatar(String? avatar) {
  if (avatar == null || avatar.isEmpty) return true;
  if (avatar == kGenericDefaultAvatar) return true;
  if (avatar.startsWith(_kEngineAvatarMarkerPrefix)) return true;
  if (avatar.startsWith(_kEngineAssetPrefix)) return true;
  return false;
}
