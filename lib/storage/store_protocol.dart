/// store.* 帧模型、路径规范化与 ACL 判定（docs/storage_protocol_spec.md v1）。
///
/// 本文件为纯逻辑：不含文件系统与网络，所有判定可单测（含攻击 fixture）。
library;

/// 协议版本。v2 新增 import.*；v3 新增 sync.hello；v4 新增 master 迁移/指针；
/// v4.2 新增版本化 URI（versions.*/manifest）与交接（handoff.*/artifact.state）。
const int kStoreProtocolVersion = 4;

/// peer 层控制帧路由 type / 协议命名空间。
const String kStoreControlType = 'store';

/// store.* 操作（spec §2）。
class StoreOp {
  StoreOp._();

  static const list = 'list';
  static const meta = 'meta';
  static const read = 'read';
  static const writeBegin = 'write.begin';
  static const writeChunk = 'write.chunk';
  static const commit = 'commit';
  static const delete = 'delete';
  static const recycleList = 'recycle.list';
  static const recycleRestore = 'recycle.restore';
  static const recycleEmpty = 'recycle.empty';
  static const stats = 'stats';

  // 换机导入授权（v2，spec §5）
  static const importRequest = 'import.request';
  static const importPending = 'import.pending';
  static const importGrant = 'import.grant';
  static const importGrants = 'import.grants';
  static const importReject = 'import.reject';

  // 变更游标对账（v3，spec §6）
  static const syncHello = 'sync.hello';
  // master 迁移与指针（v4，方案 §6.5）
  static const syncCursors = 'sync.cursors';
  static const masterPointer = 'master.pointer';
  static const masterPointerQuery = 'master.pointer.query';
  static const masterMigrate = 'master.migrate';

  // v4.2 版本化与血缘（spec §1.5）
  static const versionsList = 'versions.list';
  static const versionsRead = 'versions.read';
  static const manifest = 'manifest';
  // v4.2 交接与产物状态机（spec §2.9）
  static const handoffCreate = 'handoff.create';
  static const handoffAck = 'handoff.ack';
  static const artifactState = 'artifact.state';

  // v4.3 空间属性模型（Step 2）
  static const spaceList = 'space.list';
  static const spaceDeclare = 'space.declare';

  // v4.3 M5 App 通道（search / events.list）
  static const search = 'search';
  static const eventsList = 'events.list';

  /// 出站分享目录宣布（无 req_id 通知帧）：本机分享给对端的 space/path 白名单。
  static const shareAnnounce = 'share.announce';

  static const result = 'result';
  static const error = 'error';
}

/// 错误码（spec §1）。
class StoreError {
  StoreError._();

  static const unsupportedVersion = 'unsupported_version';
  static const untrusted = 'untrusted';
  static const notPaired = 'not_paired';
  static const aclDenied = 'acl_denied';
  static const badPath = 'bad_path';
  static const badOp = 'bad_op';
  static const hashMismatch = 'hash_mismatch';
  static const notFound = 'not_found';
  static const ambiguousRef = 'ambiguous_ref';
  static const badUri = 'bad_uri';
  static const quotaExceeded = 'quota_exceeded';
  static const stateConflict = 'state_conflict';
  static const stagingState = 'staging_state';
  static const masterOffline = 'master_offline';
  static const notMaster = 'not_master';
  static const internal = 'internal';
}

/// 目录分区（spec §0 / docs/CLIENT_PROFILES.md）。
class StoreSpace {
  StoreSpace._();

  /// 跨 owner 共享工作区（owner 可跨 device 读写）。
  static const workspaces = 'workspaces';
  /// Agent/群运行时镜像与 channel 附件/产物（默认 private）。
  static const runtime = 'runtime';
  static const files = 'files';
  static const public_ = 'public';
  static const backups = 'backups';

  /// Legacy：旧产物区（只读兼容；新写入走 [runtime]）。
  static const artifacts = 'artifacts';
  /// Legacy：旧私有附件区（只读兼容）。
  static const attachments = 'attachments';

  /// Legacy chat uploads under `files/chat/<sha256>`（旧 URI 兼容）。
  static const chatAttachmentPrefix = 'chat';
  /// Agent 结构化记忆权威空间（`memory/<agentId>/entries/*.json`）。
  static const memory = 'memory';

  /// 同步/导出枚举：新内置 + legacy（旧树仍需镜像）。
  static const all = <String>[
    workspaces,
    runtime,
    files,
    public_,
    backups,
    memory,
    artifacts,
    attachments,
  ];

  /// Browser chips：用户可见区（不含 backups 密文；legacy artifacts 仍可浏览）。
  static const browserSpaces = <String>[
    workspaces,
    runtime,
    files,
    public_,
    memory,
    artifacts,
  ];

  /// Owner 端默认可跨端读的分区（不含 private 的 runtime / memory）。
  static const sharedReadable = <String>[
    workspaces,
    files,
    public_,
    artifacts,
  ];

  /// Owner 默认可跨 device **写** 的分区（仅 workspaces）。
  static const ownerCrossWritable = <String>[workspaces];

  static bool isValid(String s) => all.contains(s);

  static bool isOwnerCrossWritable(String s) => ownerCrossWritable.contains(s);

  /// 自定义空间语法：`^[a-z][a-z0-9-]{0,31}$`（与 Rust space.declare 一致）。
  static bool isValidSyntax(String s) =>
      s.length >= 1 &&
      s.length <= 32 &&
      RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(s);
}

/// 一帧 store.* 消息。
class StoreFrame {
  StoreFrame({required this.op, required this.payload, this.reqId, this.v = 1});

  final String op;
  final String? reqId;
  final int v;

  /// op 特有字段（不含 type/ns/op/v/req_id）。
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': kStoreControlType,
        'ns': kStoreControlType,
        'op': op,
        'v': v,
        if (reqId != null) 'req_id': reqId,
        ...payload,
      };

  static StoreFrame? tryParse(Map<String, dynamic> json) {
    if (json['ns'] != kStoreControlType) return null;
    final op = json['op'];
    if (op is! String) throw const FormatException('store frame missing op');
    final payload = Map<String, dynamic>.of(json)
      ..remove('type')
      ..remove('ns')
      ..remove('op')
      ..remove('v')
      ..remove('req_id');
    return StoreFrame(
      op: op,
      reqId: json['req_id'] as String?,
      v: json['v'] as int? ?? 0,
      payload: payload,
    );
  }

  bool get versionSupported => v >= 1 && v <= kStoreProtocolVersion;

  String? get space => payload['space'] as String?;
  String? get device => payload['device'] as String?;
  String? get path => payload['path'] as String?;

  @override
  String toString() => 'StoreFrame($op req=$reqId)';
}

/// 成功响应帧。
StoreFrame storeResult(String? reqId, Map<String, dynamic> data) => StoreFrame(
    op: StoreOp.result, reqId: reqId, payload: <String, dynamic>{'data': data});

/// 失败响应帧。
StoreFrame storeError(String? reqId, String code, [String? message]) =>
    StoreFrame(op: StoreOp.error, reqId: reqId, payload: <String, dynamic>{
      'code': code,
      if (message != null) 'message': message,
    });

// ─────────────────────────────────────────────────────────────────────────────
// 路径规范化（spec §4）
// ─────────────────────────────────────────────────────────────────────────────

class BadPathException implements Exception {
  BadPathException(this.reason);
  final String reason;
  @override
  String toString() => 'BadPathException: $reason';
}

/// 规范化 store 相对路径：统一分隔符、去冗余段、拒绝危险形态。
/// 返回规范化后的相对路径（不含首尾 `/`）；非法时抛 [BadPathException]。
String normalizeStorePath(String raw) {
  if (raw.isEmpty) throw BadPathException('empty path');
  if (raw.contains('\x00')) throw BadPathException('NUL in path');
  if (raw.startsWith('/') || raw.startsWith('~') || raw.startsWith('\\')) {
    throw BadPathException('absolute path');
  }
  // Windows 盘符 / UNC（含 `\\?\` 扩展路径与 `//server/...`）
  if (RegExp(r'^[a-zA-Z]:[\\/]?').hasMatch(raw) ||
      raw.startsWith('\\\\') ||
      raw.startsWith('//')) {
    throw BadPathException('drive/unc path');
  }
  final segments = raw.replaceAll('\\', '/').split('/');
  final out = <String>[];
  for (final seg in segments) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') throw BadPathException('path traversal');
    if (seg.startsWith('.')) throw BadPathException('dot segment: $seg');
    out.add(seg);
  }
  if (out.isEmpty) throw BadPathException('resolves to empty');
  return out.join('/');
}

/// device_id 形态校验（16 hex，Noise 公钥哈希）。
bool isValidDeviceId(String? device) =>
    device != null && RegExp(r'^[0-9a-f]{16}$').hasMatch(device);

/// 内容哈希形态（64 hex）。
bool isValidContentSha256(String? sha) =>
    sha != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha);

// ─────────────────────────────────────────────────────────────────────────────
// store URI 与版本引用（spec §1.5，v4.2）
// ─────────────────────────────────────────────────────────────────────────────

enum StoreUriRefKind { latest, hash, seq }

/// `store://<space>/<device>/<path>@<ref>` 的版本引用段。
class StoreUriRef {
  const StoreUriRef.latest()
      : kind = StoreUriRefKind.latest,
        value = null;
  const StoreUriRef.hash(String this.value) : kind = StoreUriRefKind.hash;
  const StoreUriRef.seq(int value)
      : value = value,
        kind = StoreUriRefKind.seq;

  final StoreUriRefKind kind;
  final Object? value;

  bool get isLatest => kind == StoreUriRefKind.latest;

  @override
  String toString() => switch (kind) {
        StoreUriRefKind.latest => '',
        StoreUriRefKind.hash => '@$value',
        StoreUriRefKind.seq => '@v$value',
      };
}

/// 解析 store:// URI（含可选 `@ref` / `?ref=`），返回 space/device/path/ref。
/// 与 Rust `src/uri.rs` 对齐：畸形引用 → [FormatException](bad_uri)；
/// 点段/穿越 → [BadPathException]。
///
/// [allowEmptyPath] 为 true 时允许分区根 `store://<space>/<device>`（浏览/list）；
/// 读文件仍应保持默认（必须带 path）。
({String space, String device, String path, StoreUriRef ref}) parseStoreUri(
    String raw, {bool allowEmptyPath = false}) {
  final withoutQuery = raw.split('?').first;
  final rest =
      withoutQuery.startsWith('store://') ? withoutQuery.substring(8) : raw;
  final segments = rest.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length < 2 ||
      (!allowEmptyPath && segments.length < 3)) {
    throw FormatException(allowEmptyPath
        ? 'bad_uri: missing space/device'
        : 'bad_uri: missing space/device/path');
  }
  final space = segments[0];
  // 自定义空间：语法合法即可（属性/ACL 由服务端 space registry 裁定）。
  if (!StoreSpace.isValidSyntax(space)) {
    throw FormatException('bad_uri: unknown space $space');
  }
  final device = segments[1];
  if (!isValidDeviceId(device)) {
    throw FormatException('bad_uri: invalid device id');
  }
  // Markdown / Uri.tryParse 常把非 ASCII 路径编成 %XX；磁盘上是 UTF-8 文件名。
  var rel = segments
      .sublist(2)
      .map(_decodeStoreUriSegment)
      .join('/');

  // 点前缀段保留（.staging/.recycle/.versions/.nexuspouch 系统目录）。
  for (final seg in rel.split('/')) {
    if (seg.isEmpty) continue;
    if (seg.startsWith('.')) throw BadPathException('dot segment: $seg');
    if (seg == '..') throw BadPathException('path traversal');
  }

  var ref = const StoreUriRef.latest();
  final at = rel.lastIndexOf('@');
  if (at >= 0) {
    final suffix = rel.substring(at + 1);
    final parsed = _parseRefToken(suffix);
    if (parsed != null) {
      rel = rel.substring(0, at);
      ref = parsed;
    } else if (_looksLikeRefAttempt(suffix)) {
      throw FormatException('bad_uri: invalid version ref @$suffix');
    }
  }
  if (ref.isLatest) {
    final query = raw.contains('?') ? raw.substring(raw.indexOf('?') + 1) : '';
    final refParam = query.split('&').firstWhere(
        (kv) => kv.startsWith('ref='),
        orElse: () => '');
    if (refParam.isNotEmpty) {
      final v = refParam.substring(4);
      ref = _parseRefToken(v) ?? (throw FormatException('bad_uri: invalid ref $v'));
    }
  }
  return (space: space, device: device, path: rel, ref: ref);
}

/// Decode one path segment; leave alone if not valid percent-encoding.
String _decodeStoreUriSegment(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } catch (_) {
    return segment;
  }
}

StoreUriRef? parseStoreVersionRef(String s) {
  if (s.startsWith('@')) s = s.substring(1);
  if (s.startsWith('?ref=')) s = s.substring(5);
  return _parseRefToken(s);
}

StoreUriRef? _parseRefToken(String s) {
  if (s.length >= 16 && RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(s)) {
    return StoreUriRef.hash(s.toLowerCase());
  }
  if (s.startsWith('v')) {
    final n = int.tryParse(s.substring(1));
    if (n != null && n >= 1) return StoreUriRef.seq(n);
  }
  return null;
}

bool _looksLikeRefAttempt(String s) =>
    s.startsWith('v') ||
    (s.isNotEmpty && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) ||
    (s.length >= 16 && RegExp(r'^[0-9a-zA-Z]+$').hasMatch(s));

/// 格式化带版本引用的 store URI。
String storeUriWithRef(String space, String device, String path,
        [StoreUriRef? ref]) =>
    'store://$space/$device/$path${ref?.toString() ?? ''}';

/// 文件分享链接：Markdown `[displayName](storeUri)`。
String formatStoreMarkdownLink(String displayName, String storeUri) =>
    '[$displayName]($storeUri)';

// ─────────────────────────────────────────────────────────────────────────────
// ACL 判定（spec §3）
// ─────────────────────────────────────────────────────────────────────────────

/// ACL 判定结果。
enum StoreAcl { allow, denyUntrusted, denyAcl, denyBadOp, denyBadPath }

/// 信任等级。
class TrustLevel {
  TrustLevel._();
  static const owner = 'owner';
  static const friend = 'friend';
}

/// store.* 帧的 ACL 判定（纯函数）。
///
/// [callerDeviceId] 调用者设备 id（Noise 对端公钥哈希；loopback 为本机 id）。
/// [trustLevel] 调用者信任分级。
/// [loopback] 是否 master 本机用户本地调用（recycle.empty 唯一放行路径）。
/// [shareAllowed] 跨端读/删 shared 分区时的 path 白名单；`null` 时 owner 保持
/// 整区开放（测试/存量兼容），friend 拒绝跨端 shared 访问。
///
/// 注意：`seed: true` 在 ACL 层对 owner 粗放行；服务侧须另做短时授权
/// （见 [SeedAuthorization]，由 `sync.cursors` 开启）。
StoreAcl checkStoreAcl(
  StoreFrame frame, {
  required String callerDeviceId,
  required String trustLevel,
  required bool loopback,
  bool Function(String space, String? path)? shareAllowed,
}) =>
    checkStoreAclWith(
      frame,
      callerDeviceId: callerDeviceId,
      trustLevel: trustLevel,
      loopback: loopback,
      visibility: _builtinVisibility,
      shareAllowed: shareAllowed,
    );

/// 内置空间可见性：`true`=shared，`false`=private，`null`=未知。
bool? _builtinVisibility(String space) => switch (space) {
      StoreSpace.workspaces ||
      StoreSpace.files ||
      StoreSpace.public_ ||
      StoreSpace.artifacts =>
        true,
      StoreSpace.runtime ||
      StoreSpace.attachments ||
      StoreSpace.backups =>
        false,
      _ => null,
    };

/// friend 仍一律拒绝的管理/同步类 op（不可靠白名单开放）。
bool _friendDeniedOp(String op) => switch (op) {
      StoreOp.recycleList ||
      StoreOp.recycleRestore ||
      StoreOp.recycleEmpty ||
      StoreOp.importRequest ||
      StoreOp.importPending ||
      StoreOp.importGrant ||
      StoreOp.importReject ||
      StoreOp.importGrants ||
      StoreOp.syncHello ||
      StoreOp.syncCursors ||
      StoreOp.masterPointer ||
      StoreOp.masterPointerQuery ||
      StoreOp.masterMigrate ||
      StoreOp.spaceDeclare ||
      StoreOp.spaceList ||
      StoreOp.stats ||
      StoreOp.search ||
      StoreOp.eventsList ||
      StoreOp.handoffCreate ||
      StoreOp.handoffAck =>
        true,
      _ => false,
    };

/// 跨端访问 shared 分区时是否允许（读/删）。
StoreAcl _crossSharedAccess({
  required String trustLevel,
  required String space,
  required String? path,
  required bool Function(String space, String? path)? shareAllowed,
}) {
  if (shareAllowed != null) {
    return shareAllowed(space, path) ? StoreAcl.allow : StoreAcl.denyAcl;
  }
  // 无白名单回调：owner 整区兼容；friend 拒绝
  if (trustLevel == TrustLevel.owner) return StoreAcl.allow;
  return StoreAcl.denyAcl;
}

/// 属性驱动 ACL（Step 2）：`visibility(space)` 返回 `true`(shared) /
/// `false`(private) / `null`(未知)。未知空间 → denyBadOp。
StoreAcl checkStoreAclWith(
  StoreFrame frame, {
  required String callerDeviceId,
  required String trustLevel,
  required bool loopback,
  bool? Function(String space)? visibility,
  bool Function(String space, String? path)? shareAllowed,
}) {
  bool? vis(String s) => visibility?.call(s) ?? _builtinVisibility(s);
  final isOwner = trustLevel == TrustLevel.owner;
  if (!isOwner && _friendDeniedOp(frame.op)) {
    return StoreAcl.denyUntrusted;
  }

  final space = frame.space;
  final device = frame.device;
  bool known(String s) => vis(s) != null || StoreSpace.isValid(s);
  bool shared(String s) => vis(s) == true;

  switch (frame.op) {
    // ── 写操作：默认目标目录恒为调用者；workspaces 允许 owner 跨 device 写 ──
    case StoreOp.writeBegin:
    case StoreOp.writeChunk:
    case StoreOp.commit:
    case StoreOp.handoffCreate:
      if (space != null && !known(space)) {
        return StoreAcl.denyBadOp;
      }
      // write.begin 必须带 space；chunk/commit 以 upload_id 关联（space 可省）
      if (frame.op == StoreOp.writeBegin && space == null) {
        return StoreAcl.denyBadOp;
      }
      if (device != null && device != callerDeviceId) {
        // workspaces：owner 可写任意 owner 设备目录；friend / 其它 space 拒绝
        if (space != null &&
            StoreSpace.isOwnerCrossWritable(space) &&
            isOwner &&
            isValidDeviceId(device)) {
          return StoreAcl.allow;
        }
        return StoreAcl.denyAcl;
      }
      return StoreAcl.allow;

    // ── 删除：共享分区可删他端（须白名单）；私有分区仅本端 ──
    case StoreOp.delete:
    case StoreOp.handoffAck:
      if (space == null || !known(space)) {
        return StoreAcl.denyBadOp;
      }
      final targetOwn = device == null || device == callerDeviceId;
      if (!targetOwn) {
        if (!shared(space)) return StoreAcl.denyAcl;
        final cross = _crossSharedAccess(
          trustLevel: trustLevel,
          space: space,
          path: frame.path,
          shareAllowed: shareAllowed,
        );
        if (cross != StoreAcl.allow) return cross;
      }
      if (device != null && !isValidDeviceId(device)) {
        return StoreAcl.denyBadOp;
      }
      return StoreAcl.allow;

    // ── 读取类：共享分区可读他端（须白名单）；私有分区仅本端——
    // 或持有效换机导入授权（grant）；或升主种子拷贝（seed: true，owner）──
    case StoreOp.list:
    case StoreOp.meta:
    case StoreOp.read:
    case StoreOp.versionsList:
    case StoreOp.versionsRead:
    case StoreOp.manifest:
    case StoreOp.artifactState:
      if (space == null || !known(space)) {
        return StoreAcl.denyBadOp;
      }
      final targetOwn = device == null || device == callerDeviceId;
      if (!targetOwn && shared(space)) {
        final path = frame.op == StoreOp.list
            ? (frame.payload['path'] as String?)
            : frame.path;
        final cross = _crossSharedAccess(
          trustLevel: trustLevel,
          space: space,
          path: path,
          shareAllowed: shareAllowed,
        );
        if (cross != StoreAcl.allow) return cross;
      } else if (!targetOwn && !shared(space)) {
        // seed:true：ACL 粗放行；运行时由 SeedAuthorization 收敛为迁移窗口
        final seed = frame.payload['seed'] == true;
        if (seed) {
          if (!isOwner) return StoreAcl.denyUntrusted;
          if (!isValidDeviceId(device)) {
            return StoreAcl.denyBadOp;
          }
          return StoreAcl.allow;
        }
        final grant = frame.payload['grant'];
        if (grant is! String || grant.isEmpty) return StoreAcl.denyAcl;
        if (!isOwner) return StoreAcl.denyUntrusted;
      }
      if (device != null && !isValidDeviceId(device)) {
        return StoreAcl.denyBadOp;
      }
      return StoreAcl.allow;

    // ── 回收站 ──
    case StoreOp.recycleList:
    case StoreOp.recycleRestore:
      return StoreAcl.allow; // owner 级（spec §3 M2 从宽）
    case StoreOp.recycleEmpty:
      // 仅 master 本机用户（loopback）
      return loopback ? StoreAcl.allow : StoreAcl.denyAcl;

    // ── 换机导入授权（v2）──
    case StoreOp.importRequest:
      // 新设备 → 旧设备/master 发起；目标不能是自己
      final oldDevice = frame.payload['old_device'];
      if (!isValidDeviceId(oldDevice) || oldDevice == callerDeviceId) {
        return StoreAcl.denyBadOp;
      }
      return StoreAcl.allow;
    case StoreOp.importPending:
      return StoreAcl.allow;
    case StoreOp.importGrant:
    case StoreOp.importReject:
    case StoreOp.importGrants:
      // 签发/拒绝/授权清单：仅服务侧本机用户（用户在场确认是信任锚）
      return loopback ? StoreAcl.allow : StoreAcl.denyAcl;

    case StoreOp.stats:
    case StoreOp.spaceList:
    case StoreOp.search:
    case StoreOp.eventsList:
      return StoreAcl.allow;
    case StoreOp.spaceDeclare:
      // 自定义空间声明：仅 master 本机（loopback）
      return loopback ? StoreAcl.allow : StoreAcl.denyAcl;

    // 游标对账：仅本设备目录（spec §6.2）
    case StoreOp.syncHello:
      final device = frame.payload['device'];
      if (!isValidDeviceId(device) || device != callerDeviceId) {
        return StoreAcl.denyAcl;
      }
      return StoreAcl.allow;

    // master 迁移（v4，方案 §6.5）：owner 可读游标账 / 查指针；
    // master.migrate 仅目标本机 loopback 或由对方主动执行（入站允许 owner 触发）
    case StoreOp.syncCursors:
    case StoreOp.masterPointerQuery:
      return StoreAcl.allow;
    case StoreOp.masterMigrate:
      // 远端请求本机升主：owner 可触发；正式落盘仍在本机编排
      return StoreAcl.allow;
    case StoreOp.masterPointer:
      // 通知帧在入站早退；若落入 ACL 则允许 owner
      return StoreAcl.allow;

    case StoreOp.shareAnnounce:
      // 通知帧在入站早退；落入 ACL 时放行（owner/friend 均可推送自己的分享目录）
      return StoreAcl.allow;

    default:
      // 未知 op（含伪造的授权类 op）
      return StoreAcl.denyBadOp;
  }
}

/// ACL 结果 → 错误码。
String storeAclErrorCode(StoreAcl verdict) => switch (verdict) {
      StoreAcl.denyUntrusted => StoreError.untrusted,
      StoreAcl.denyAcl => StoreError.aclDenied,
      StoreAcl.denyBadOp => StoreError.badOp,
      StoreAcl.denyBadPath => StoreError.badPath,
      StoreAcl.allow => StoreError.internal,
    };
