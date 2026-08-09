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
///
/// Channel 与 workflow 步隔离目录分离：
/// `runtime/<owner>/<channel_id>/[wf_<wf>__step_<step>/]…`
///
/// 历史 peer session id 仍可能是 `channel__wf_<wf>__step_<step>` 单段字符串；
/// [channelRoot] 会按 [workflowScopeMarker] 拆成两级目录。
class RuntimePaths {
  RuntimePaths._();

  /// peer / 工作流 scoped session id 中，channel 与 wf 段的拼接标记。
  static const workflowScopeMarker = '__wf_';

  static String sanitizeSegment(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '_default';
    return s
        .replaceAll(RegExp(r'[/\\]+'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'[^\w.\-@+]'), '_');
  }

  /// `wf_<workflowId>__step_<workflowStepId>`（channel 下的独立目录名）。
  static String? workflowScopeDir({
    required String? workflowId,
    required String? workflowStepId,
  }) {
    if (workflowId == null ||
        workflowId.isEmpty ||
        workflowStepId == null ||
        workflowStepId.isEmpty) {
      return null;
    }
    return 'wf_${sanitizeSegment(workflowId)}__step_${sanitizeSegment(workflowStepId)}';
  }

  /// 将 `channel__wf_x__step_y` 拆成 channel + `wf_x__step_y`。
  static ({String channelId, String? workflowScope}) splitChannelId(
    String raw,
  ) {
    final i = raw.indexOf(workflowScopeMarker);
    if (i <= 0) {
      return (channelId: raw, workflowScope: null);
    }
    // `__wf_…` → 丢掉前导 `__`，目录名为 `wf_…`
    return (
      channelId: raw.substring(0, i),
      workflowScope: raw.substring(i + 2),
    );
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

  /// `owner/<channel>/[wf_…__step_…/]`
  ///
  /// [channelId] 可为裸 channel，或历史拼接的 `channel__wf_…__step_…`。
  /// [workflowScope] 非空时优先用作第二段（不再从 channelId 拆）。
  static String channelRoot(
    String ownerId,
    String channelId, {
    String? workflowScope,
  }) {
    final owner = sanitizeSegment(ownerId);
    if (workflowScope != null && workflowScope.trim().isNotEmpty) {
      return '$owner/${sanitizeSegment(channelId)}/'
          '${sanitizeSegment(workflowScope)}';
    }
    final parts = splitChannelId(channelId);
    final ch = sanitizeSegment(parts.channelId);
    final scope = parts.workflowScope;
    if (scope == null || scope.isEmpty) {
      return '$owner/$ch';
    }
    return '$owner/$ch/${sanitizeSegment(scope)}';
  }

  static String sessionJson(
    String ownerId,
    String channelId, {
    String? workflowScope,
  }) =>
      '${channelRoot(ownerId, channelId, workflowScope: workflowScope)}'
      '/sessions/session.json';

  static String sessionArchive(
    String ownerId,
    String channelId,
    String utcStamp, {
    String? workflowScope,
  }) =>
      '${channelRoot(ownerId, channelId, workflowScope: workflowScope)}'
      '/sessions/archive-${sanitizeSegment(utcStamp)}.json';

  static String attachmentsDir(
    String ownerId,
    String channelId, {
    String? workflowScope,
  }) =>
      '${channelRoot(ownerId, channelId, workflowScope: workflowScope)}'
      '/attachments';

  static String attachmentBlob(
    String ownerId,
    String channelId,
    String sha256, {
    String? workflowScope,
  }) =>
      '${attachmentsDir(ownerId, channelId, workflowScope: workflowScope)}'
      '/$sha256';

  static String artifactsDir(
    String ownerId,
    String channelId, {
    String? workflowScope,
  }) =>
      '${channelRoot(ownerId, channelId, workflowScope: workflowScope)}'
      '/artifacts';

  static String artifactFile({
    required String ownerId,
    required String channelId,
    required String taskId,
    required String filename,
    String? workflowScope,
  }) =>
      '${artifactsDir(ownerId, channelId, workflowScope: workflowScope)}'
      '/${sanitizeSegment(taskId)}/$filename';

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
