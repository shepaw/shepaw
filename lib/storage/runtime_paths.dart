/// Runtime / workspace 路径约定（docs/CLIENT_PROFILES.md）。
///
/// App 聊天权威仍在 SQLite；本文件只描述储物袋镜像与附件/产物落点。
library;

import 'store_protocol.dart';

/// 解析后的 runtime 归属（本机写入用）。
class RuntimeOwner {
  const RuntimeOwner({
    required this.ownerId,
    required this.deviceId,
    this.placement = 'local',
  });

  /// `agent_id` 或 `group_id`（目录第一段）。
  final String ownerId;

  /// 实体写入的 device_id（Noise 指纹）。
  final String deviceId;

  /// `local` | `peer` | `hub` | `local_fallback`
  final String placement;
}

/// 路径构建器（不含 device；URI 由 [storeUriWithRef] 组装）。
class RuntimePaths {
  RuntimePaths._();

  static String sanitizeSegment(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '_default';
    return s
        .replaceAll(RegExp(r'[/\\]+'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'[^\w.\-@+]'), '_');
  }

  /// 群聊优先 [parentGroupId]，否则群 channel id；单聊用 [agentId]。
  static String resolveOwnerId({
    required String agentId,
    String? channelId,
    String? channelType,
    String? parentGroupId,
  }) {
    if (channelType == 'group') {
      final g = parentGroupId?.trim();
      if (g != null && g.isNotEmpty) return sanitizeSegment(g);
      if (channelId != null && channelId.isNotEmpty) {
        return sanitizeSegment(channelId);
      }
    }
    return sanitizeSegment(agentId);
  }

  static String runtimeRoot(String ownerId) => sanitizeSegment(ownerId);

  static String soulMd(String ownerId) =>
      '${runtimeRoot(ownerId)}/soul.md';

  static String memoryMd(String ownerId) =>
      '${runtimeRoot(ownerId)}/memory.md';

  static String workspaceMd(String ownerId) =>
      '${runtimeRoot(ownerId)}/workspace.md';

  static String contextManifest(String ownerId) =>
      '${runtimeRoot(ownerId)}/context.manifest.json';

  static String channelRoot(String ownerId, String channelId) =>
      '${runtimeRoot(ownerId)}/${sanitizeSegment(channelId)}';

  static String sessionJson(String ownerId, String channelId) =>
      '${channelRoot(ownerId, channelId)}/sessions/session.json';

  static String attachmentsDir(String ownerId, String channelId) =>
      '${channelRoot(ownerId, channelId)}/attachments';

  static String attachmentBlob(
    String ownerId,
    String channelId,
    String sha256,
  ) =>
      '${attachmentsDir(ownerId, channelId)}/$sha256';

  static String artifactsDir(String ownerId, String channelId) =>
      '${channelRoot(ownerId, channelId)}/artifacts';

  static String artifactFile({
    required String ownerId,
    required String channelId,
    required String taskId,
    required String filename,
  }) =>
      '${artifactsDir(ownerId, channelId)}/${sanitizeSegment(taskId)}/$filename';

  /// 是否为 runtime 下聊天附件路径：`…/attachments/<sha256>`。
  static bool isRuntimeAttachmentPath(String relPath) {
    final parts = relPath.split('/');
    if (parts.length < 4) return false;
    if (parts[parts.length - 2] != 'attachments') return false;
    return RegExp(r'^[0-9a-f]{64}$', caseSensitive: false)
        .hasMatch(parts.last);
  }

  /// 组装 runtime 区 URI。
  static String uri({
    required String deviceId,
    required String relPath,
  }) =>
      storeUriWithRef(StoreSpace.runtime, deviceId, relPath);
}
