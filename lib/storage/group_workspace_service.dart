import 'dart:convert';
import 'dart:typed_data';

import '../models/group_task.dart';
import '../models/group_task_artifact.dart';
import '../peer/models/peer_store_share.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'group_workspace_scopes.dart';
import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_scope_store.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'store_uri_reader.dart';

/// 群工作空间元数据。
///
/// 物理文件：`workspaces/<homeDevice>/group_<gid>/group-workspace.json`。
/// 成员表是「群工作空间只有 members 可读写」这一权限模型的唯一依据。
class GroupWorkspaceMeta {
  GroupWorkspaceMeta({
    required this.schemaVersion,
    required this.groupId,
    required this.homeDevice,
    required this.members,
    this.commitSeq = 0,
    this.archive = false,
  });

  final int schemaVersion;
  final String groupId;

  /// 空间归属设备（workspaces 目录第一段）。M1 为创建设备；跨设备写经
  /// [StoreService.writeWorkspaceFile] 以该设备为 home device。
  final String homeDevice;

  /// agentId → 成员信息（含 role / deviceId / joinedAt）。
  final Map<String, GroupWorkspaceMember> members;
  final int commitSeq;

  /// 群删除后标记归档，不物理删除（储物袋「删除由用户手动操作」原则）。
  final bool archive;

  bool isMember(String agentId) => members.containsKey(agentId);

  GroupWorkspaceMeta copyWith({
    Map<String, GroupWorkspaceMember>? members,
    int? commitSeq,
    bool? archive,
  }) {
    return GroupWorkspaceMeta(
      schemaVersion: schemaVersion,
      groupId: groupId,
      homeDevice: homeDevice,
      members: members ?? this.members,
      commitSeq: commitSeq ?? this.commitSeq,
      archive: archive ?? this.archive,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'group_id': groupId,
        'home_device': homeDevice,
        'members': {
          for (final e in members.entries) e.key: e.value.toJson(),
        },
        'shared': {'commit_seq': commitSeq, 'archive': archive},
      };

  static GroupWorkspaceMeta? fromJson(Map<String, dynamic> json) {
    final gid = json['group_id'] as String?;
    final home = json['home_device'] as String?;
    if (gid == null || gid.isEmpty || home == null || home.isEmpty) {
      return null;
    }
    final members = <String, GroupWorkspaceMember>{};
    final rawMembers = json['members'];
    if (rawMembers is Map) {
      for (final e in rawMembers.entries) {
        final v = e.value;
        if (v is Map) {
          final m = GroupWorkspaceMember.fromJson(
            e.key,
            Map<String, dynamic>.from(v),
          );
          if (m != null) members[e.key] = m;
        }
      }
    }
    final shared = json['shared'];
    var commitSeq = 0;
    var archive = false;
    if (shared is Map) {
      commitSeq = (shared['commit_seq'] as num?)?.toInt() ?? 0;
      archive = shared['archive'] as bool? ?? false;
    }
    return GroupWorkspaceMeta(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      groupId: gid,
      homeDevice: home,
      members: members,
      commitSeq: commitSeq,
      archive: archive,
    );
  }
}

/// 单个群成员的元数据。
class GroupWorkspaceMember {
  GroupWorkspaceMember({
    required this.agentId,
    required this.role,
    required this.joinedAt,
    this.deviceId = '',
  });

  final String agentId;

  /// `admin`（群主/She）或 `member`。
  final String role;
  final String joinedAt;

  /// 成员宿主设备（M1 可能为空；跨设备 ACL 下发时填充）。
  final String deviceId;

  Map<String, dynamic> toJson() => {
        'role': role,
        'device_id': deviceId,
        'joined_at': joinedAt,
      };

  static GroupWorkspaceMember? fromJson(String agentId, Map<String, dynamic> json) {
    final role = json['role'] as String?;
    if (role == null || role.isEmpty) return null;
    return GroupWorkspaceMember(
      agentId: agentId,
      role: role,
      deviceId: json['device_id'] as String? ?? '',
      joinedAt: json['joined_at'] as String? ?? '',
    );
  }
}

/// 外接 agent MCP 群工具在群工作空间 inbox 写入的编排决定。
///
/// 字段与 `group-mcp.ts`（agent-bridge）写入的 payload 对应：
/// - [dispatch]：`{issued_at, kind: 'dispatch', mode, steps: [{step, agents, task}]}`
/// - [finish]：`{issued_at, kind: 'finish', action: done|continue|pause}`
/// - [mentions]：`{issued_at, kind: 'mention', mentions: [{name, notify?, reason?}]}`
class OrchestrationInbox {
  const OrchestrationInbox({
    this.dispatch,
    this.finish,
    this.mentions,
  });

  final Map<String, dynamic>? dispatch;
  final Map<String, dynamic>? finish;
  final Map<String, dynamic>? mentions;

  bool get isEmpty => dispatch == null && finish == null && mentions == null;
}

/// 群工作空间服务。
///
/// 空间布局：
/// ```
/// workspaces/<homeDevice>/<group id>/
/// ├── group-workspace.json         # 成员表（读写权限唯一依据）
/// ├── members/<agentId>/...        # 成员私有区（pouch write 落点，只写自己的）
/// └── shared/
///     ├── tasks/
///     │   ├── index.json
///     │   └── <orchestrationId>/
///     │       ├── task.json
///     │       ├── requirement.md
///     │       ├── plan.md / plan.json
///     │       ├── results.json
///     │       └── archive.md
///     └── orchestration/<sessionId>/round-N/{state.json, dispatch.json}
/// ```
///
/// 所有写入经 [StoreService.writeWorkspaceFile]（workspaces 跨 device 写通道，
/// commit 内联进 SyncJournal 自动镜像到 master）；读取经 [StoreUriReader]。
class GroupWorkspaceService {
  GroupWorkspaceService._();
  static final instance = GroupWorkspaceService._();

  static const schemaVersion = 1;

  /// 元数据文件名（无前导点：协议层 normalizeStorePath 拒绝 dot segment）。
  static const metaFileName = 'group-workspace.json';

  /// 目录根。群 id 就是 `group_<uuid>`，不再另加前缀。
  String workspaceRoot(String groupId) =>
      RuntimePaths.sanitizeSegment(groupId);

  String metaRelPath(String groupId) =>
      '${workspaceRoot(groupId)}/$metaFileName';

  /// 成员私有区：`<group id>/members/<agentId>`。
  String membersDir(String groupId, String agentId) =>
      '${workspaceRoot(groupId)}/members/'
      '${RuntimePaths.sanitizeSegment(agentId)}';

  /// 单任务编排根：`<group id>/shared/orchestration/<sessionId>`。
  String orchestrationRoot(String groupId, String sessionId) =>
      '${workspaceRoot(groupId)}/shared/orchestration/'
      '${RuntimePaths.sanitizeSegment(sessionId)}';

  /// 轮目录：`…/orchestration/<sessionId>/round-N`（N 左补零 4 位）。
  String roundDir(String groupId, String sessionId, int round) =>
      '${orchestrationRoot(groupId, sessionId)}/'
      'round-${round.toString().padLeft(4, '0')}';

  /// 群事件日志目录：`…/orchestration/<sessionId>/events`（互相感知事件系统，
  /// 与轮次目录隔离，避免与编排轮 state.json 冲突）。
  String eventsDir(String groupId, String sessionId) =>
      '${orchestrationRoot(groupId, sessionId)}/events';

  /// 外接 agent（group MCP 工具）写入的 inbox 目录：
  /// `…/orchestration/<sessionId>/inbox`。
  String inboxDir(String groupId, String sessionId) =>
      '${orchestrationRoot(groupId, sessionId)}/inbox';

  /// 群任务根：`<group id>/shared/tasks`。
  String tasksRoot(String groupId) =>
      '${workspaceRoot(groupId)}/shared/tasks';

  /// 单任务目录：`…/shared/tasks/<orchestrationId>`。
  String taskDir(String groupId, String orchestrationId) =>
      '${tasksRoot(groupId)}/${RuntimePaths.sanitizeSegment(orchestrationId)}';

  String taskIndexRelPath(String groupId) =>
      '${tasksRoot(groupId)}/index.json';

  String taskJsonRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/task.json';

  String taskRequirementRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/requirement.md';

  String taskPlanMdRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/plan.md';

  String taskPlanJsonRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/plan.json';

  String taskResultsRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/results.json';

  String taskArchiveRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/archive.md';

  String taskArtifactPlanRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/artifact_plan.json';

  String taskArtifactsRelPath(String groupId, String orchestrationId) =>
      '${taskDir(groupId, orchestrationId)}/artifacts.json';

  /// 构建群任务相关文件的袋子地址（`group:<gid>:shared/...`）。
  ///
  /// 群空间不存在返回 null；路径不在群共享区或未配对时抛错。
  Future<String?> taskFileUri({
    required String groupId,
    required String relPath,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final target = _scopeTarget(relPath);
    final scoped = await _scopes();
    return scoped.uriFor(target.scope, target.path).format();
  }

  /// 幂等创建群工作空间骨架 + 元数据。已存在时补缺成员，返回空间根。
  ///
  /// [homeDeviceId] 缺省为本机 device id。骨架目录写 `.keep` 占位文件
  /// 确保目录存在（workspaces 目录随写入隐式创建）。
  Future<String> ensureGroupWorkspace({
    required String groupId,
    String? homeDeviceId,
    List<({String agentId, String role})>? members,
  }) async {
    final root = workspaceRoot(groupId);
    final home = homeDeviceId ?? await DeviceIdentity.deviceId();
    final existing = await loadMeta(groupId);
    if (existing != null) {
      // 已有元数据：合并补缺成员（新成员 upsert，已存在不覆盖 role/joinedAt）。
      if (members != null && members.isNotEmpty) {
        var changed = false;
        final merged = Map<String, GroupWorkspaceMember>.from(existing.members);
        final now = DateTime.now().toIso8601String();
        for (final m in members) {
          if (!merged.containsKey(m.agentId)) {
            merged[m.agentId] = GroupWorkspaceMember(
              agentId: m.agentId,
              role: m.role,
              joinedAt: now,
            );
            changed = true;
          }
        }
        if (changed) {
          await _writeMeta(existing.copyWith(members: merged));
        }
      }
      return root;
    }

    final now = DateTime.now().toIso8601String();
    final meta = GroupWorkspaceMeta(
      schemaVersion: schemaVersion,
      groupId: groupId,
      homeDevice: home,
      members: {
        if (members != null)
          for (final m in members)
            m.agentId: GroupWorkspaceMember(
              agentId: m.agentId,
              role: m.role,
              joinedAt: now,
            ),
      },
    );
    await _writeMeta(meta);
    // 目录随首次写入隐式创建（储物袋 workspaces 无显式 mkdir）；
    // 骨架即「元数据文件 + 目录命名约定」。
    return root;
  }

  /// 读取空间元数据；不存在返回 null。
  Future<GroupWorkspaceMeta?> loadMeta(String groupId) async {
    try {
      final uri = await metaUri(groupId);
      if (uri == null) return null;
      final bytes = await StoreUriReader.instance.read(uri);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) return null;
      return GroupWorkspaceMeta.fromJson(json);
    } catch (e) {
      LoggerService().debug(
        'group workspace meta not found for $groupId: $e',
        tag: 'GroupWorkspaceService',
      );
      return null;
    }
  }

  /// 解析元数据 URI；不确定 home device 时先读本机（M1 单机场景）。
  Future<String?> metaUri(String groupId) async {
    // 群元数据仍走 v2：它由 hub 的 `system/groups.json` +
    // `group:<gid>/meta.json` 接管之前，这里保持原来的按路径读取。
    return 'pouch://workspaces/${metaRelPath(groupId)}';
  }

  /// 新增/更新成员（role 为空时保持原值）。
  Future<void> upsertMember({
    required String groupId,
    required String agentId,
    String? role,
    String? deviceId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return;
    final now = DateTime.now().toIso8601String();
    final merged = Map<String, GroupWorkspaceMember>.from(meta.members);
    final existing = merged[agentId];
    merged[agentId] = GroupWorkspaceMember(
      agentId: agentId,
      role: role ?? existing?.role ?? 'member',
      joinedAt: existing?.joinedAt ?? now,
      deviceId: deviceId ?? existing?.deviceId ?? '',
    );
    await _writeMeta(meta.copyWith(members: merged));
  }

  /// 移除成员（只更新元数据，不删成员文件）。
  Future<void> removeMember({
    required String groupId,
    required String agentId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null || !meta.members.containsKey(agentId)) return;
    final merged = Map<String, GroupWorkspaceMember>.from(meta.members)
      ..remove(agentId);
    await _writeMeta(meta.copyWith(members: merged));
  }

  /// 写一轮编排状态，同时更新 `latest.json` 指针（读「最新」只读一个文件）。
  ///
  /// [payload] 必须是可 JSON 序列化的 Map（含 `status` / `round` 等字段）。
  Future<void> writeRoundState({
    required String groupId,
    required String sessionId,
    required int round,
    required Map<String, dynamic> payload,
  }) async {
    await _writeJson(
      groupId: groupId,
      relPath: '${roundDir(groupId, sessionId, round)}/state.json',
      payload: payload,
    );
    await _writeJson(
      groupId: groupId,
      relPath: '${orchestrationRoot(groupId, sessionId)}/latest.json',
      payload: {
        'round': round,
        'status': payload['status'],
        'updated_at': DateTime.now().toIso8601String(),
      },
    );
  }

  /// 写一条群事件日志（互相感知事件系统）。写在专用 `events/` 目录，
  /// 按 [seq] 顺序编号，供跨重启恢复最近事件。失败不影响调用方（best-effort）。
  Future<void> writeEventLog({
    required String groupId,
    required String sessionId,
    required int seq,
    required Map<String, dynamic> payload,
  }) async {
    await _writeJson(
      groupId: groupId,
      relPath:
          '${eventsDir(groupId, sessionId)}/${seq.toString().padLeft(6, '0')}.json',
      payload: payload,
    );
  }

  /// 读取某会话事件日志目录中的全部事件（崩溃恢复回放用），按 seq 升序返回。
  ///
  /// 目录不存在返回空列表；单条文件缺失/损坏忽略（best-effort，与写入一致）。
  Future<List<({int seq, Map<String, dynamic> payload})>> readEventLogs({
    required String groupId,
    required String sessionId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return const [];
    final dir = eventsDir(groupId, sessionId);
    final List<StoreEntry> entries;
    try {
      entries = await _listWorkspace(dir);
    } catch (e) {
      LoggerService().debug(
        'group event log list failed: $dir — $e',
        tag: 'GroupWorkspaceService',
      );
      return const [];
    }

    final results = <({int seq, Map<String, dynamic> payload})>[];
    for (final e in entries) {
      if (e.isDir) continue;
      final name = e.path.split('/').last;
      if (!name.endsWith('.json')) continue;
      final seq = int.tryParse(name.substring(0, name.length - 5));
      if (seq == null) continue;
      final payload = await _readJson(e.path);
      if (payload == null) continue;
      results.add((seq: seq, payload: payload));
    }
    results.sort((a, b) => a.seq.compareTo(b.seq));
    return results;
  }

  /// 写一回合的 dispatch 决定（解析后结构，非原始 JSON 块）。
  Future<void> writeRoundDispatch({
    required String groupId,
    required String sessionId,
    required int round,
    required Map<String, dynamic> payload,
  }) async {
    await _writeJson(
      groupId: groupId,
      relPath: '${roundDir(groupId, sessionId, round)}/dispatch.json',
      payload: payload,
    );
  }

  /// 读取指定轮次的编排状态；不存在返回 null。
  Future<Map<String, dynamic>?> readRoundState({
    required String groupId,
    required String sessionId,
    required int round,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readJson('${roundDir(groupId, sessionId, round)}/state.json');
  }

  /// 读取指定轮次的 dispatch 决定（解析后结构）；不存在返回 null。
  Future<Map<String, dynamic>?> readRoundDispatch({
    required String groupId,
    required String sessionId,
    required int round,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readJson('${roundDir(groupId, sessionId, round)}/dispatch.json');
  }

  /// 外接 agent MCP 群工具写入的编排决定（inbox 文件）。
  ///
  /// [homeDevice] 为外接 agent 的 hub 设备（从其 metadata workspace_uri
  /// 解析）；经 [StoreUriReader] 跨设备读（workspaces 是 shared 分区）。
  /// 只返回 `issued_at` 晚于 [since] 的文件——宿主编排循环每轮记录
  /// 本轮开始时间，只消费本轮内新写入的决定（不删除、无并发问题）。
  Future<OrchestrationInbox> readOrchestrationInbox({
    required String groupId,
    required String sessionId,
    required DateTime since,
    String? homeDevice,
  }) async {
    if (homeDevice == null || homeDevice.isEmpty) {
      return const OrchestrationInbox();
    }
    final dir = inboxDir(groupId, sessionId);
    final sinceIso = since.toUtc().toIso8601String();

    Future<Map<String, dynamic>?> readIfFresh(String file) async {
      final data = await _readJson('$dir/$file');
      if (data == null) return null;
      final issued = data['issued_at'] as String?;
      if (issued == null || issued.compareTo(sinceIso) <= 0) return null;
      return data;
    }

    return OrchestrationInbox(
      dispatch: await readIfFresh('dispatch.json'),
      finish: await readIfFresh('finish.json'),
      mentions: await readIfFresh('mentions.json'),
    );
  }

  /// 整轮摘要：state + dispatch 合并（编排状态详情面板用）。
  Future<Map<String, dynamic>?> readRoundSummary({
    required String groupId,
    required String sessionId,
    required int round,
  }) async {
    final state = await readRoundState(
      groupId: groupId,
      sessionId: sessionId,
      round: round,
    );
    if (state == null) return null;
    final dispatch = await readRoundDispatch(
      groupId: groupId,
      sessionId: sessionId,
      round: round,
    );
    return {...state, if (dispatch != null) 'dispatch': dispatch};
  }

  /// 读取最新轮次指针（恢复入口）；不存在返回 null。
  Future<Map<String, dynamic>?> readLatestOrchestration({
    required String groupId,
    required String sessionId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readJson('${orchestrationRoot(groupId, sessionId)}/latest.json');
  }

  /// 最新编排轮次号（来自 `latest.json`）；不存在返回 null。
  Future<int?> latestOrchestrationRound({
    required String groupId,
    required String sessionId,
  }) async {
    final latest = await readLatestOrchestration(
      groupId: groupId,
      sessionId: sessionId,
    );
    final round = latest?['round'];
    if (round is int) return round;
    if (round is num) return round.toInt();
    return null;
  }

  /// 读取最新群记忆（`shared/memory/latest.md`，纯文本）；无内容返回 null。
  Future<String?> readSharedMemoryLatest(String groupId) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final root = workspaceRoot(groupId);
    try {
      final bytes =
          await _readWorkspace('$root/shared/memory/latest.md');
      final text = utf8.decode(bytes).trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      LoggerService().debug(
        'group memory latest read failed: $e',
        tag: 'GroupWorkspaceService',
      );
      return null;
    }
  }

  /// 写入 session 级交接包（`shared/handoffs/<handoffId>.json` + `.md`）。
  ///
  /// 供群管理员 `group_session_create` / CLI 使用；JSON 为机器解析源，
  /// Markdown 为人类可读伴生文件。返回 JSON 的 store URI。
  Future<({String jsonUri, String mdUri})?> writeSharedHandoff({
    required String groupId,
    required String handoffId,
    required String jsonContent,
    required String markdownContent,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final root = workspaceRoot(groupId);
    final safeId = RuntimePaths.sanitizeSegment(handoffId);
    final jsonRel = '$root/shared/handoffs/$safeId.json';
    final mdRel = '$root/shared/handoffs/$safeId.md';
    try {
      final jsonUri = await _writeWorkspace(
        relPath: jsonRel,
        bytes: Uint8List.fromList(utf8.encode(jsonContent)),
      );
      final mdUri = await _writeWorkspace(
        relPath: mdRel,
        bytes: Uint8List.fromList(utf8.encode(markdownContent)),
      );
      return (jsonUri: jsonUri, mdUri: mdUri);
    } catch (e) {
      LoggerService().error(
        'group workspace handoff write failed: $groupId/$handoffId',
        tag: 'GroupWorkspaceService',
        error: e,
      );
      return null;
    }
  }

  /// 写入群记忆蒸馏摘要（任务完成时由编排器调用）。
  ///
  /// 内容 = 编排 finish 轮的 admin 总结（零额外 LLM 调用）；落
  /// `shared/memory/<sessionId>.md` 并按任务完成顺序覆盖 `latest.md`
  /// （最新任务结论，跨任务共享注入点）。返回 latest 的 store URI。
  Future<String?> writeSharedMemory({
    required String groupId,
    required String sessionId,
    required String content,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final root = workspaceRoot(groupId);
    final bytes = Uint8List.fromList(utf8.encode(content));
    final sessionRel =
        '$root/shared/memory/${RuntimePaths.sanitizeSegment(sessionId)}.md';
    final latestRel = '$root/shared/memory/latest.md';
    try {
      await _writeWorkspace(
        relPath: sessionRel,
        bytes: bytes,
      );
      return await _writeWorkspace(
        relPath: latestRel,
        bytes: bytes,
      );
    } catch (e) {
      LoggerService().error(
        'group workspace memory write failed: $groupId',
        tag: 'GroupWorkspaceService',
        error: e,
      );
      return null;
    }
  }

  /// 写成员私有区的一份文件（`members/<agentId>/<relPath>`），返回袋子地址。
  ///
  /// 落 `group:<gid>:member:<aid>`；没有袋子时由 [_scopes] 抛出未配对错误。
  /// 调用方负责先校验群成员身份与相对路径。
  Future<String> writeMemberFile({
    required String groupId,
    required String agentId,
    required String relPath,
    required Uint8List bytes,
  }) async {
    return _writeWorkspace(
      relPath: '${membersDir(groupId, agentId)}/$relPath',
      bytes: bytes,
    );
  }

  // ---------------------------------------------------------------------------
  // 群任务（shared/tasks/<orchestrationId>/）
  // ---------------------------------------------------------------------------

  /// 读取任务索引；不存在返回空索引。
  Future<GroupTaskIndex> readTaskIndex(String groupId) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return GroupTaskIndex();
    final json = await _readJson(taskIndexRelPath(groupId));
    if (json == null) return GroupTaskIndex();
    return GroupTaskIndex.fromJson(json);
  }

  Future<void> _writeTaskIndex(String groupId, GroupTaskIndex index) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return;
    await _writeJson(
      groupId: groupId,
      relPath: taskIndexRelPath(groupId),
      payload: index.toJson(),
    );
  }

  /// 创建任务主记录（`task.json`）并更新索引。
  ///
  /// [orchestrationId] 通常为触发编排的用户消息 id；[sessionId] 为频道 id。
  Future<GroupTask?> createTask({
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required String userGoal,
    String status = GroupTask.statusClarifying,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;

    final task = GroupTask(
      orchestrationId: orchestrationId,
      sessionId: sessionId,
      status: status,
      userGoal: userGoal.trim(),
    );
    await _writeJson(
      groupId: groupId,
      relPath: taskJsonRelPath(groupId, orchestrationId),
      payload: task.toJson(),
    );
    final index = await readTaskIndex(groupId);
    await _writeTaskIndex(groupId, index.withActiveTask(task));
    return task;
  }

  /// 幂等创建：已存在则直接返回，否则 [createTask]。
  Future<GroupTask?> ensureTask({
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required String userGoal,
    String status = GroupTask.statusClarifying,
  }) async {
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (existing != null) return existing;
    return createTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
      sessionId: sessionId,
      userGoal: userGoal,
      status: status,
    );
  }

  /// 读取任务主记录；不存在返回 null。
  Future<GroupTask?> readTask({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final json = await _readJson(taskJsonRelPath(groupId, orchestrationId));
    if (json == null) return null;
    return GroupTask.fromJson(json);
  }

  /// 更新任务主记录并同步索引 recent 条目。
  Future<GroupTask?> writeTask({
    required String groupId,
    required GroupTask task,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final updated = task.copyWith(updatedAt: DateTime.now());
    await _writeJson(
      groupId: groupId,
      relPath: taskJsonRelPath(groupId, task.orchestrationId),
      payload: updated.toJson(),
    );
    final index = await readTaskIndex(groupId);
    await _writeTaskIndex(groupId, index.withActiveTask(updated));
    return updated;
  }

  /// 更新任务状态（便捷封装）。
  Future<GroupTask?> updateTaskStatus({
    required String groupId,
    required String orchestrationId,
    required String status,
    DateTime? finishedAt,
  }) async {
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (existing == null) return null;
    final terminal = GroupTask.isTerminalStatus(status);
    return writeTask(
      groupId: groupId,
      task: existing.copyWith(
        status: status,
        finishedAt: terminal ? (finishedAt ?? DateTime.now()) : null,
        clearFinishedAt: !terminal,
      ),
    );
  }

  /// 写入定稿需求（`requirement.md`）并回写 task.json URI。
  Future<({GroupTask task, String uri})?> writeTaskRequirement({
    required String groupId,
    required String orchestrationId,
    required String content,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (existing == null) return null;

    final rel = taskRequirementRelPath(groupId, orchestrationId);
    final uri = await _writeTextFile(
      relPath: rel,
      content: content,
    );
    final task = await writeTask(
      groupId: groupId,
      task: existing.copyWith(requirementUri: uri),
    );
    if (task == null) return null;
    return (task: task, uri: uri);
  }

  /// 读取定稿需求；不存在返回 null。
  Future<String?> readTaskRequirement({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readText(taskRequirementRelPath(groupId, orchestrationId));
  }

  /// 发布任务计划：写 plan.json + plan.md，更新 task 状态为 planned。
  Future<({GroupTask task, String planUri, String planJsonUri})?> writeTaskPlan({
    required String groupId,
    required GroupTaskPlan plan,
    String requirementNotes = '',
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: plan.orchestrationId,
    );
    if (existing == null) return null;

    final mdRel = taskPlanMdRelPath(groupId, plan.orchestrationId);
    final jsonRel = taskPlanJsonRelPath(groupId, plan.orchestrationId);
    final planUri = await _writeTextFile(
      relPath: mdRel,
      content: plan.toMarkdown(requirementNotes: requirementNotes),
    );
    final planJsonUri = await _writeJson(
      groupId: groupId,
      relPath: jsonRel,
      payload: plan.toJson(),
    );
    final task = await writeTask(
      groupId: groupId,
      task: existing.copyWith(
        status: GroupTask.statusPlanned,
        planUri: planUri,
        planJsonUri: planJsonUri,
      ),
    );
    if (task == null) return null;
    return (task: task, planUri: planUri, planJsonUri: planJsonUri);
  }

  /// 读取结构化计划；不存在返回 null。
  Future<GroupTaskPlan?> readTaskPlanJson({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final json = await _readJson(taskPlanJsonRelPath(groupId, orchestrationId));
    if (json == null) return null;
    return GroupTaskPlan.fromJson(json);
  }

  /// 读取人类可读计划；不存在返回 null。
  Future<String?> readTaskPlanMarkdown({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readText(taskPlanMdRelPath(groupId, orchestrationId));
  }

  /// 写入/覆盖成员结果汇总（`results.json`）。
  Future<({GroupTaskResults results, String uri})?> writeTaskResults({
    required String groupId,
    required GroupTaskResults results,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: results.orchestrationId,
    );
    if (existing == null) return null;

    final rel = taskResultsRelPath(groupId, results.orchestrationId);
    final uri = await _writeJson(
      groupId: groupId,
      relPath: rel,
      payload: results.toJson(),
    );
    await writeTask(
      groupId: groupId,
      task: existing.copyWith(resultsUri: uri),
    );
    return (results: results, uri: uri);
  }

  /// 追加或更新单个成员结果条目。
  Future<GroupTaskResults?> upsertTaskMemberResult({
    required String groupId,
    required String orchestrationId,
    required GroupTaskMemberResult memberResult,
  }) {
    return upsertTaskMemberResults(
      groupId: groupId,
      orchestrationId: orchestrationId,
      entries: [memberResult],
    );
  }

  /// 批量追加/更新多条成员结果（单轮一次读改写）。
  ///
  /// [GroupResultWriter.persistFromTurns] 每轮先内存汇总全部成员再调用一次，
  /// 避免旧 [upsertTaskMemberResult] 每成员一次 read+merge+整写
  /// results.json/task.json/index.json 的 K 倍放大（每成员约 5 次 loadMeta
  /// + 3 次整写）。
  Future<GroupTaskResults?> upsertTaskMemberResults({
    required String groupId,
    required String orchestrationId,
    required List<GroupTaskMemberResult> entries,
  }) async {
    if (entries.isEmpty) return null;
    final existing = await readTaskResults(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    var merged = existing ?? GroupTaskResults(orchestrationId: orchestrationId);
    for (final entry in entries) {
      merged = merged.upsertMember(entry);
    }
    final written = await writeTaskResults(
      groupId: groupId,
      results: merged,
    );
    return written?.results;
  }

  /// 读取成员结果汇总；不存在返回 null。
  Future<GroupTaskResults?> readTaskResults({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final json = await _readJson(taskResultsRelPath(groupId, orchestrationId));
    if (json == null) return null;
    return GroupTaskResults.fromJson(json);
  }

  /// 写入任务卷宗（`archive.md`）并回写 task.json URI。
  Future<({GroupTask task, String uri})?> writeTaskArchive({
    required String groupId,
    required String orchestrationId,
    required String content,
    String? finalSummaryUri,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (existing == null) return null;

    final rel = taskArchiveRelPath(groupId, orchestrationId);
    final uri = await _writeTextFile(
      relPath: rel,
      content: content,
    );
    final task = await writeTask(
      groupId: groupId,
      task: existing.copyWith(
        archiveUri: uri,
        finalSummaryUri: finalSummaryUri ?? existing.finalSummaryUri,
      ),
    );
    if (task == null) return null;
    return (task: task, uri: uri);
  }

  /// 读取任务卷宗；不存在返回 null。
  Future<String?> readTaskArchive({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readText(taskArchiveRelPath(groupId, orchestrationId));
  }

  /// 写入/覆盖产物落点规划（`artifact_plan.json`）。
  Future<GroupTaskArtifactPlan?> writeTaskArtifactPlan({
    required String groupId,
    required GroupTaskArtifactPlan plan,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: plan.orchestrationId,
    );
    if (existing == null) return null;

    final rel = taskArtifactPlanRelPath(groupId, plan.orchestrationId);
    final uri = await _writeJson(
      groupId: groupId,
      relPath: rel,
      payload: plan.toJson(),
    );
    await writeTask(
      groupId: groupId,
      task: existing.copyWith(artifactPlanUri: uri),
    );
    return plan;
  }

  /// 读取产物落点规划；不存在返回 null。
  Future<GroupTaskArtifactPlan?> readTaskArtifactPlan({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final json = await _readJson(taskArtifactPlanRelPath(groupId, orchestrationId));
    if (json == null) return null;
    return GroupTaskArtifactPlan.fromJson(json);
  }

  /// 登记产物条目（合并写入 `artifacts.json`）。
  Future<GroupTaskArtifactManifest?> registerTaskArtifacts({
    required String groupId,
    required String orchestrationId,
    required List<GroupTaskArtifactEntry> entries,
  }) async {
    if (entries.isEmpty) return null;
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final existing = await readTask(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (existing == null) return null;

    final current = await readTaskArtifactManifest(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    final merged = (current ??
            GroupTaskArtifactManifest(orchestrationId: orchestrationId))
        .registerAll(entries);

    final rel = taskArtifactsRelPath(groupId, orchestrationId);
    final uri = await _writeJson(
      groupId: groupId,
      relPath: rel,
      payload: merged.toJson(),
    );
    await writeTask(
      groupId: groupId,
      task: existing.copyWith(artifactsUri: uri),
    );
    return merged;
  }

  /// 读取产物聚合清单；不存在返回 null。
  Future<GroupTaskArtifactManifest?> readTaskArtifactManifest({
    required String groupId,
    required String orchestrationId,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final json = await _readJson(taskArtifactsRelPath(groupId, orchestrationId));
    if (json == null) return null;
    return GroupTaskArtifactManifest.fromJson(json);
  }

  /// 校验 agent 是否为群成员（store CLI 路径权限依据）。
  Future<bool> isMember(String groupId, String agentId) async {
    final meta = await loadMeta(groupId);
    return meta?.isMember(agentId) ?? false;
  }

  /// 回收 peer 成员设备的群工作空间访问（踢成员时调用）。
  ///
  /// 移除 `members/<agentId>/` 白名单条目；`shared` 前缀保留（其他成员
  /// 仍需要读共享面）。失败仅记录（成员表已移除，CLI 层 isMember 校验
  /// 仍会拒绝）。
  /// 注：v3 袋子里的 `group:<gid>:member:<aid>` 由 hub 的 scope ACL 按 agent
  /// 身份管；这条 v2 白名单只影响旧 `workspaces/` 目录的跨设备访问。
  Future<void> revokePeerAccess({
    required String groupId,
    required String agentId,
    required String peerId,
  }) async {
    try {
      final existing =
          await PeerStorageService().getSharedStoreEntries(peerId);
      final memberPrefix =
          '${workspaceRoot(groupId)}/members/'
          '${RuntimePaths.sanitizeSegment(agentId)}';
      final kept = existing.where(
        (e) =>
            !(e.space == StoreSpace.workspaces && e.path == memberPrefix),
      );
      await StoreService.instance.setOutboundStoreShares(peerId, kept);
    } catch (e) {
      LoggerService().error(
        'revoke peer group workspace access failed: $peerId',
        tag: 'GroupWorkspaceService',
        error: e,
      );
    }
  }

  /// 向 peer 成员设备自动下发群工作空间访问白名单（跨设备 ACL）。
  ///
  /// - owner 级设备：默认整区开放（[PeerStorageService.effectiveOutboundAllowlist]
  ///   回退 ownerDefaults 含 workspaces），显式写前缀反而收窄访问，不动；
  /// - friend 级设备：追加 `members/<agentId>/` 与 `shared` 前缀条目。
  ///
  /// 幂等：同 space/path 条目已存在则跳过；失败仅记录（不阻断建群/加成员）。
  /// 注：细粒度成员校验仍在 store CLI 层（[GroupWorkspaceService.isMember]），
  /// 设备白名单只是粗粒度闸门。
  /// 注：成员私有区的新写入落 `group:<gid>:member:<aid>`，由 hub 的 scope ACL
  /// 按 agent 身份鉴权；下面的 v2 白名单只为旧 `workspaces/` 目录保留。
  Future<void> grantPeerAccess({
    required String groupId,
    required String agentId,
    required String peerId,
  }) async {
    try {
      final peer = await PeerStorageService().getPeerById(peerId);
      if (peer == null || peer.trustLevel == TrustLevel.owner) return;
      final existing =
          await PeerStorageService().getSharedStoreEntries(peerId);
      final entries = [...existing];

      void addIfAbsent(String path) {
        final already = entries
            .any((e) => e.space == StoreSpace.workspaces && e.path == path);
        if (!already) {
          entries.add(PeerStoreShareEntry(
            space: StoreSpace.workspaces,
            path: path,
            shared: true,
          ));
        }
      }

      final root = workspaceRoot(groupId);
      addIfAbsent(
          '$root/members/${RuntimePaths.sanitizeSegment(agentId)}');
      addIfAbsent('$root/shared');
      await StoreService.instance.setOutboundStoreShares(peerId, entries);
    } catch (e) {
      LoggerService().error(
        'grant peer group workspace access failed: $peerId',
        tag: 'GroupWorkspaceService',
        error: e,
      );
    }
  }

  /// 写群元数据（`<gid>/group-workspace.json`）。
  ///
  /// 这是 App 侧仅剩的 v2 写入：成员/角色/homDevice 还没搬进 hub 的
  /// `system/groups.json` + `group:<gid>/meta.json`，等 hub 的群 API 接管后
  /// 这里一起删。群内容（shared/members/任务/事件）已经全部走 v3。
  Future<void> _writeMeta(GroupWorkspaceMeta meta) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson())));
    await StoreService.instance.writeWorkspaceFile(
      homeDeviceId: meta.homeDevice,
      relPath: metaRelPath(meta.groupId),
      content: bytes,
    );
  }

  /// 写 JSON，返回袋子地址。
  Future<String> _writeJson({
    required String groupId,
    required String relPath,
    required Map<String, dynamic> payload,
    Uint8List? bytes,
  }) async {
    final content = bytes ??
        Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    try {
      return await _writeWorkspace(relPath: relPath, bytes: content);
    } catch (e) {
      LoggerService().error(
        'group workspace write failed: $relPath',
        tag: 'GroupWorkspaceService',
        error: e,
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _readJson(String relPath) async {
    try {
      final bytes = await _readWorkspace(relPath);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is Map<String, dynamic>) return json;
    } catch (e) {
      LoggerService().debug(
        'group workspace read failed: $relPath — $e',
        tag: 'GroupWorkspaceService',
      );
    }
    return null;
  }

  /// 写文本，返回袋子地址。
  Future<String> _writeTextFile({
    required String relPath,
    required String content,
  }) =>
      _writeWorkspace(
        relPath: relPath,
        bytes: Uint8List.fromList(utf8.encode(content)),
      );

  Future<String?> _readText(String relPath) async {
    try {
      final bytes = await _readWorkspace(relPath);
      final text = utf8.decode(bytes).trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      LoggerService().debug(
        'group workspace text read failed: $relPath — $e',
        tag: 'GroupWorkspaceService',
      );
      return null;
    }
  }

  // ── 袋子里的群工作区（v2 目录已停用） ─────────────────────────────────────

  static ({PouchScope scope, String path}) _scopeTarget(String workspacePath) {
    final target = GroupWorkspaceScopes.map(workspacePath);
    if (target == null) {
      throw StateError('group workspace path is not scoped: $workspacePath');
    }
    return target;
  }

  Future<PouchScopeStore> _scopes() => StoreService.instance.scopeStore();

  /// 读工作区内容：只认 `group:<gid>:shared` / `group:<gid>:member:<aid>`。
  Future<Uint8List> _readWorkspace(String workspacePath) async {
    final target = _scopeTarget(workspacePath);
    final scoped = await _scopes();
    final bytes = await scoped.read(target.scope, target.path);
    if (bytes == null) {
      throw StoreException(StoreError.notFound, workspacePath);
    }
    return bytes;
  }

  /// 列工作区目录，返回的 [StoreEntry.path] 都是工作区相对路径。
  Future<List<StoreEntry>> _listWorkspace(String workspacePath) async {
    final target = _scopeTarget(workspacePath);
    final scoped = await _scopes();
    final entries = await scoped.listChildren(
      target.scope,
      path: target.path,
    );
    return <StoreEntry>[
      for (final entry in entries)
        if (_workspaceRel(entry.path, target.path) case final rel?)
          StoreEntry(
            path: '$workspacePath/$rel',
            size: entry.size,
            sha256: entry.sha256,
            mtimeMs: entry.mtimeMs,
            kind: entry.kind,
          ),
    ];
  }

  /// `listChildren` 给的是 scope 内相对路径（含 [base] 前缀），换回目录内相对路径。
  static String? _workspaceRel(String path, String base) {
    final rel = path.startsWith('$base/')
        ? path.substring(base.length + 1)
        : path;
    if (rel.isEmpty || rel == base) return null;
    return rel;
  }

  /// 写工作区内容，返回袋子地址。
  Future<String> _writeWorkspace({
    required String relPath,
    required Uint8List bytes,
  }) async {
    final target = _scopeTarget(relPath);
    final scoped = await _scopes();
    return scoped.write(target.scope, target.path, bytes);
  }
}
