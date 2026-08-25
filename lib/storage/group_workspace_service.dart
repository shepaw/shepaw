import 'dart:convert';
import 'dart:typed_data';

import '../peer/models/peer_store_share.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
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
/// workspaces/<homeDevice>/group_<gid>/
/// ├── group-workspace.json         # 成员表（读写权限唯一依据）
/// ├── members/<agentId>/...        # 成员私有区（store write 落点，只写自己的）
/// └── shared/
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

  /// 目录根（`group_<gid>`，段已 sanitize）。
  String workspaceRoot(String groupId) =>
      'group_${RuntimePaths.sanitizeSegment(groupId)}';

  String metaRelPath(String groupId) =>
      '${workspaceRoot(groupId)}/$metaFileName';

  /// 成员私有区：`group_<gid>/members/<agentId>`。
  String membersDir(String groupId, String agentId) =>
      '${workspaceRoot(groupId)}/members/'
      '${RuntimePaths.sanitizeSegment(agentId)}';

  /// 单任务编排根：`group_<gid>/shared/orchestration/<sessionId>`。
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
    final self = await DeviceIdentity.deviceId();
    // 优先本机（M1 空间归属创建设备）；跨设备读取后续接 ACL 后补齐。
    return 'store://workspaces/$self/${metaRelPath(groupId)}';
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
    final meta = await loadMeta(groupId);
    final home = meta?.homeDevice ?? await DeviceIdentity.deviceId();
    await _writeJson(
      groupId: groupId,
      homeDeviceId: home,
      relPath: '${roundDir(groupId, sessionId, round)}/state.json',
      payload: payload,
    );
    await _writeJson(
      groupId: groupId,
      homeDeviceId: home,
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
    final meta = await loadMeta(groupId);
    final home = meta?.homeDevice ?? await DeviceIdentity.deviceId();
    await _writeJson(
      groupId: groupId,
      homeDeviceId: home,
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
    final home = meta.homeDevice;
    final dir = eventsDir(groupId, sessionId);
    final List<StoreEntry> entries;
    try {
      entries = await StoreService.instance.listDevice(
        deviceId: home,
        space: StoreSpace.workspaces,
        prefix: dir,
        depth: 1,
        computeHash: false,
      );
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
      final payload = await _readJson('store://workspaces/$home/${e.path}');
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
    final meta = await loadMeta(groupId);
    final home = meta?.homeDevice ?? await DeviceIdentity.deviceId();
    await _writeJson(
      groupId: groupId,
      homeDeviceId: home,
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
    return _readJson(
      'store://workspaces/${meta.homeDevice}/'
      '${roundDir(groupId, sessionId, round)}/state.json',
    );
  }

  /// 读取指定轮次的 dispatch 决定（解析后结构）；不存在返回 null。
  Future<Map<String, dynamic>?> readRoundDispatch({
    required String groupId,
    required String sessionId,
    required int round,
  }) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    return _readJson(
      'store://workspaces/${meta.homeDevice}/'
      '${roundDir(groupId, sessionId, round)}/dispatch.json',
    );
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
      final data = await _readJson(
        'store://workspaces/$homeDevice/$dir/$file',
      );
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
    return _readJson(
      'store://workspaces/${meta.homeDevice}/'
      '${orchestrationRoot(groupId, sessionId)}/latest.json',
    );
  }

  /// 读取最新群记忆（`shared/memory/latest.md`，纯文本）；无内容返回 null。
  Future<String?> readSharedMemoryLatest(String groupId) async {
    final meta = await loadMeta(groupId);
    if (meta == null) return null;
    final root = workspaceRoot(groupId);
    try {
      final bytes = await StoreUriReader.instance.read(
        'store://workspaces/${meta.homeDevice}/'
        '$root/shared/memory/latest.md',
      );
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
    final home = meta.homeDevice;
    final root = workspaceRoot(groupId);
    final bytes = Uint8List.fromList(utf8.encode(content));
    final sessionRel =
        '$root/shared/memory/${RuntimePaths.sanitizeSegment(sessionId)}.md';
    final latestRel = '$root/shared/memory/latest.md';
    try {
      await StoreService.instance.writeWorkspaceFile(
        homeDeviceId: home,
        relPath: sessionRel,
        content: bytes,
      );
      await StoreService.instance.writeWorkspaceFile(
        homeDeviceId: home,
        relPath: latestRel,
        content: bytes,
      );
      return 'store://workspaces/$home/$latestRel';
    } catch (e) {
      LoggerService().error(
        'group workspace memory write failed: $groupId',
        tag: 'GroupWorkspaceService',
        error: e,
      );
      return null;
    }
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

  Future<void> _writeMeta(GroupWorkspaceMeta meta) => _writeJson(
        groupId: meta.groupId,
        homeDeviceId: meta.homeDevice,
        relPath: metaRelPath(meta.groupId),
        payload: meta.toJson(),
      );

  Future<void> _writeJson({
    required String groupId,
    required String homeDeviceId,
    required String relPath,
    required Map<String, dynamic> payload,
    Uint8List? bytes,
  }) async {
    final content = bytes ??
        Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    try {
      await StoreService.instance.writeWorkspaceFile(
        homeDeviceId: homeDeviceId,
        relPath: relPath,
        content: content,
      );
    } catch (e) {
      LoggerService().error(
        'group workspace write failed: $relPath',
        tag: 'GroupWorkspaceService',
        error: e,
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _readJson(String uri) async {
    try {
      final bytes = await StoreUriReader.instance.read(uri);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is Map<String, dynamic>) return json;
    } catch (e) {
      LoggerService().debug(
        'group workspace read failed: $uri — $e',
        tag: 'GroupWorkspaceService',
      );
    }
    return null;
  }
}
