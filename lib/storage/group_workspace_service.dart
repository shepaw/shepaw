import 'dart:convert';
import 'dart:typed_data';

import '../peer/models/peer_store_share.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
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

  /// 校验 agent 是否为群成员（store CLI 路径权限依据）。
  Future<bool> isMember(String groupId, String agentId) async {
    final meta = await loadMeta(groupId);
    return meta?.isMember(agentId) ?? false;
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
