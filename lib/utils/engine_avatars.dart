/// Peer agent 头像解析辅助：引擎默认图由 agent-bridge Hub 经 `avatar_data` 下发，
/// App 不再打包引擎 logo。本文件只识别「尚未个性化、可被同步覆盖」的占位值。

/// 通用占位头像（无引擎图 / 未知引擎时的回退）。
const String kGenericDefaultAvatar = '🤖';

/// 历史方案曾把 Flutter asset 路径当作默认头像；现已改为 Hub 下发字节。
const String _kLegacyEngineAssetPrefix = 'assets/images/engines/';

/// Hub 下发的逻辑标记（真实图在同条消息的 `avatar_data`）。
const String _kEngineAvatarMarkerPrefix = 'engine-avatar:';

/// 无可用引擎图时的回退（App 端不再内置引擎 asset）。
String defaultAvatarForEngine(String? engineId) {
  // engineId 仅作协议兼容保留；具体 logo 以 peer 下发的 avatar_data 为准。
  return kGenericDefaultAvatar;
}

/// 是否为「尚未个性化」的占位头像（可被对端同步覆盖）。
bool isGenericDefaultAvatar(String? avatar) {
  if (avatar == null || avatar.isEmpty) return true;
  if (avatar == kGenericDefaultAvatar) return true;
  if (avatar.startsWith(_kEngineAvatarMarkerPrefix)) return true;
  if (avatar.startsWith(_kLegacyEngineAssetPrefix)) return true;
  return false;
}
