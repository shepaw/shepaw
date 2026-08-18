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
    String? sourceGroupChannelId,
  }) {
    return resolveStoreTarget(
      agentId: agentId,
      channelId: channelId,
      channelType: channelType,
      parentGroupId: parentGroupId,
      sourceGroupChannelId: sourceGroupChannelId,
    ).ownerId;
  }

  /// `store write` 落点：群产物进群 runtime，不进成员自己的储物袋。
  ///
  /// - 群频道 → owner=群，channel=该群
  /// - 群绑定成员 DM（[sourceGroupChannelId]）→ owner/channel=该群
  /// - 普通单聊 → owner=agent，channel=该 DM
  static ({String ownerId, String channelId}) resolveStoreTarget({
    required String agentId,
    String? channelId,
    String? channelType,
    String? parentGroupId,
    String? sourceGroupChannelId,
  }) {
    final agent = sanitizeSegment(agentId);
    final ch = (channelId != null && channelId.trim().isNotEmpty)
        ? sanitizeSegment(channelId)
        : '';
    if (ch.isEmpty) {
      return (ownerId: agent, channelId: agent);
    }
    if (channelType == 'group') {
      final g = parentGroupId?.trim();
      final owner =
          (g != null && g.isNotEmpty) ? sanitizeSegment(g) : ch;
      return (ownerId: owner, channelId: ch);
    }
    final src = sourceGroupChannelId?.trim();
    if (src != null && src.isNotEmpty) {
      final group = sanitizeSegment(src);
      return (ownerId: group, channelId: group);
    }
    return (ownerId: agent, channelId: ch);
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

/// runtime 分享给配对设备时，文件级放行策略。
///
/// share 行仅记 owner 前缀（见 `RuntimeShareService`）；本策略把可读范围
/// 收窄到聊天附件与产物。目录始终可导航（服务端按 `entityKind` / list 的
/// `isDir` 判定），不经过这里。
///
/// 会话记录（`sessions/`）与 soul/memory/workspace 镜像、上下文清单
/// （owner 根下）不属于分享范围。
class RuntimeSharePolicy {
  RuntimeSharePolicy._();

  /// owner 根下的敏感镜像/清单文件名。
  static const _sensitiveRootFiles = {
    'soul.md',
    'memory.md',
    'workspace.md',
    'context.manifest.json',
  };

  /// 客户端快速失败预过滤：命中敏感清单（owner 根文件或任意 `sessions` 段）
  /// → true。非敏感路径放行到服务端，由 [allowsFileRead] 严格判定。
  static bool isSensitivePath(String relPath) {
    final parts = relPath.split('/');
    if (parts.length == 2 && _sensitiveRootFiles.contains(parts[1])) {
      return true;
    }
    return parts.contains('sessions');
  }

  /// 服务端严格判定：仅放行含 `attachments` / `artifacts` 段的文件。
  ///
  /// 目录由调用方按 `entityKind` 放行（可导航）；未知文件一律不放行。
  static bool allowsFileRead(String relPath) {
    if (relPath.isEmpty) return false;
    final parts = relPath.split('/');
    return parts.contains('attachments') || parts.contains('artifacts');
  }
}
