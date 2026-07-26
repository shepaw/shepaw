import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'local_store.dart' show StoreException;
import 'store_protocol.dart';

/// 新导入请求事件总线（旧设备/master 收到 `import.request` 时广播）。
class ImportRequestBus {
  ImportRequestBus._();
  static final ImportRequestBus instance = ImportRequestBus._();

  final _created = StreamController<ImportRequest>.broadcast();

  /// 新创建的 pending 请求（去重复用不触发）。
  Stream<ImportRequest> get onCreated => _created.stream;

  void emitCreated(ImportRequest request) {
    if (!_created.isClosed) _created.add(request);
  }
}

/// 导入授权（docs/storage_space_plan.md §5.4，M3）。
///
/// 一次性、限旧设备私有目录（backups/attachments）只读。
/// 签发通道即信任锚：旧设备经 Noise E2E 通道签发，或 master 用户在本机
/// 管理页手动确认（旧设备不在场路径）。
class ImportGrant {
  ImportGrant({
    required this.grantId,
    required this.oldDevice,
    required this.newDevice,
    required this.spaces,
    required this.issuedAtMs,
    required this.expiresAtMs,
    this.revoked = false,
  });

  final String grantId;
  final String oldDevice;
  final String newDevice;
  final List<String> spaces;
  final int issuedAtMs;
  final int expiresAtMs;
  bool revoked;

  bool get expired =>
      DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'grant_id': grantId,
        'old_device': oldDevice,
        'new_device': newDevice,
        'spaces': spaces,
        'issued_at': issuedAtMs,
        'expires_at': expiresAtMs,
        'revoked': revoked,
      };

  static ImportGrant fromJson(Map<String, dynamic> json) => ImportGrant(
        grantId: json['grant_id'] as String,
        oldDevice: json['old_device'] as String,
        newDevice: json['new_device'] as String,
        spaces: (json['spaces'] as List).cast<String>(),
        issuedAtMs: json['issued_at'] as int,
        expiresAtMs: json['expires_at'] as int,
        revoked: json['revoked'] as bool? ?? false,
      );
}

/// 导入请求（出现在旧设备/master 管理页待确认）。
class ImportRequest {
  ImportRequest({
    required this.requestId,
    required this.oldDevice,
    required this.newDevice,
    required this.requestedAtMs,
    this.status = 'pending',
  });

  final String requestId;
  final String oldDevice;

  /// 请求方（新设备）device_id。
  final String newDevice;
  final int requestedAtMs;

  /// pending | granted | rejected
  String status;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'request_id': requestId,
        'old_device': oldDevice,
        'new_device': newDevice,
        'requested_at': requestedAtMs,
        'status': status,
      };

  static ImportRequest fromJson(Map<String, dynamic> json) => ImportRequest(
        requestId: json['request_id'] as String,
        oldDevice: json['old_device'] as String,
        newDevice: json['new_device'] as String,
        requestedAtMs: json['requested_at'] as int,
        status: json['status'] as String? ?? 'pending',
      );
}

/// 授权与请求的持久化与校验。
///
/// 存储：store 根 `.system/` 下三个 JSON 文件——
/// requests（待审批）、grants（本机签发的授权）、received（本机收到的授权）。
class ImportAuthService {
  ImportAuthService({required Directory storeRoot})
      : _systemDir = Directory(p.join(storeRoot.path, '.system'));

  final Directory _systemDir;
  static const _uuid = Uuid();
  static const defaultTtl = Duration(hours: 24);

  /// 授权覆盖的私有分区（§5.4：backups 与 attachments）。
  static const grantSpaces = <String>['backups', 'attachments'];

  File get _requestsFile => File(p.join(_systemDir.path, 'import_requests.json'));
  File get _grantsFile => File(p.join(_systemDir.path, 'import_grants.json'));
  File get _receivedFile => File(p.join(_systemDir.path, 'import_received.json'));

  // ────────────────────────────── 请求 ──

  /// 登记一条导入请求（服务侧：旧设备或 master）。
  ///
  /// 返回 `(request, created)`；同一 (old,new) 已有 pending 时复用且 `created=false`。
  Future<({ImportRequest request, bool created})> createRequest({
    required String oldDevice,
    required String newDevice,
  }) async {
    final requests = await _loadRequests();
    // 同一 (old,new) 已有 pending 请求则复用
    final existing = requests.where((r) =>
        r.oldDevice == oldDevice &&
        r.newDevice == newDevice &&
        r.status == 'pending');
    if (existing.isNotEmpty) {
      return (request: existing.first, created: false);
    }
    final req = ImportRequest(
      requestId: 'ir-${_uuid.v4()}',
      oldDevice: oldDevice,
      newDevice: newDevice,
      requestedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    requests.add(req);
    await _saveRequests(requests);
    return (request: req, created: true);
  }

  Future<List<ImportRequest>> pendingRequests() async =>
      (await _loadRequests()).where((r) => r.status == 'pending').toList();

  // ────────────────────────────── 签发（服务侧，loopback 用户确认）──

  /// 批准请求并签发授权。
  Future<ImportGrant> grant(String requestId, {Duration? ttl}) async {
    final requests = await _loadRequests();
    ImportRequest? req;
    for (final r in requests) {
      if (r.requestId == requestId) req = r;
    }
    if (req == null) {
      throw StoreException(StoreError.notFound, 'request not found');
    }
    if (req.status != 'pending') {
      throw StoreException(StoreError.badOp, 'request already ${req.status}');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final grant = ImportGrant(
      grantId: 'ig-${_uuid.v4()}',
      oldDevice: req.oldDevice,
      newDevice: req.newDevice,
      spaces: List.of(grantSpaces),
      issuedAtMs: now,
      expiresAtMs: now + (ttl ?? defaultTtl).inMilliseconds,
    );
    final grants = await _loadGrants();
    grants.add(grant);
    await _saveGrants(grants);
    req.status = 'granted';
    await _saveRequests(requests); // 同一列表对象，状态变更随保存生效
    return grant;
  }

  Future<void> reject(String requestId) async {
    final requests = await _loadRequests();
    for (final r in requests) {
      if (r.requestId == requestId) r.status = 'rejected';
    }
    await _saveRequests(requests);
  }

  Future<void> revoke(String grantId) async {
    final grants = await _loadGrants();
    for (final g in grants) {
      if (g.grantId == grantId) g.revoked = true;
    }
    await _saveGrants(grants);
  }

  // ────────────────────────────── 校验（服务侧读路径）──

  /// 校验授权：存在、未撤销、未过期、主体与分区匹配。
  Future<bool> validate(
    String grantId, {
    required String oldDevice,
    required String newDevice,
    required String space,
  }) async {
    final grants = await _loadGrants();
    for (final g in grants) {
      if (g.grantId == grantId &&
          g.oldDevice == oldDevice &&
          g.newDevice == newDevice &&
          g.spaces.contains(space) &&
          !g.revoked &&
          !g.expired) {
        return true;
      }
    }
    return false;
  }

  // ────────────────────────────── 请求方（新设备）侧 ──

  /// 保存收到的授权（import.grant 推送帧）。
  Future<void> saveReceivedGrant(ImportGrant grant) async {
    final received = await _loadReceived();
    received.removeWhere((g) => g.grantId == grant.grantId);
    received.add(grant);
    await _saveJson(_receivedFile,
        received.map((g) => g.toJson()).toList());
  }

  /// 列出本机持有的有效授权（未过期未撤销）。
  Future<List<ImportGrant>> receivedGrants() async =>
      (await _loadReceived()).where((g) => !g.revoked && !g.expired).toList();

  /// 本机签发的授权（服务侧管理页）。
  Future<List<ImportGrant>> issuedGrants() async =>
      (await _loadGrants()).where((g) => !g.revoked && !g.expired).toList();

  // ────────────────────────────── 持久化 ──

  Future<List<ImportRequest>> _loadRequests() async {
    final raw = await _readJson(_requestsFile);
    return raw.map((e) => ImportRequest.fromJson(e)).toList();
  }

  Future<void> _saveRequests(List<ImportRequest> requests) async {
    await _saveJson(
        _requestsFile, requests.map((r) => r.toJson()).toList());
  }

  Future<List<ImportGrant>> _loadGrants() async {
    final raw = await _readJson(_grantsFile);
    return raw.map((e) => ImportGrant.fromJson(e)).toList();
  }

  Future<void> _saveGrants(List<ImportGrant> grants) async {
    await _saveJson(_grantsFile, grants.map((g) => g.toJson()).toList());
  }

  Future<List<ImportGrant>> _loadReceived() async {
    final raw = await _readJson(_receivedFile);
    return raw.map((e) => ImportGrant.fromJson(e)).toList();
  }

  Future<List<Map<String, dynamic>>> _readJson(File file) async {
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      return (decoded as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveJson(File file, List<Map<String, dynamic>> data) async {
    await file.parent.create(recursive: true);
    // 每次写独立 tmp 名：并发写不同请求互不干扰（rename 不跨名竞争）。
    final tmp = File('${file.path}.${_uuid.v4()}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(file.path);
  }
}
