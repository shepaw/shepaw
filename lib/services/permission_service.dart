/// ACP 权限管理服务
/// 管理 OpenClaw Agent 的权限请求和用户同意
library;

import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'local_storage_service.dart';
/// 权限请求状态
enum PermissionStatus {
  /// 等待审批
  pending,
  
  /// 已批准
  approved,
  
  /// 已拒绝
  rejected,
  
  /// 已过期
  expired,
}

/// 权限类型
enum PermissionType {
  /// 发起聊天
  initiateChat,
  
  /// 获取 Agent 列表
  getAgentList,
  
  /// 获取 Agent 能力
  getAgentCapabilities,
  
  /// 订阅 Channel
  subscribeChannel,

  /// 发送文件
  sendFile,

  /// 获取会话列表
  getSessions,

  /// 获取会话消息
  getSessionMessages,

  /// 获取附件内容
  getAttachmentContent,
}

/// 权限请求
class PermissionRequest {
  /// 请求 ID
  final String id;
  
  /// Agent ID
  final String agentId;
  
  /// Agent 名称
  final String agentName;
  
  /// 权限类型
  final PermissionType permissionType;
  
  /// 请求原因
  final String reason;
  
  /// 状态
  final PermissionStatus status;
  
  /// 请求时间
  final DateTime requestTime;
  
  /// 处理时间
  final DateTime? processedTime;
  
  /// 过期时间
  final DateTime? expiryTime;
  
  /// 额外数据
  final Map<String, dynamic>? metadata;

  PermissionRequest({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.permissionType,
    required this.reason,
    required this.status,
    required this.requestTime,
    this.processedTime,
    this.expiryTime,
    this.metadata,
  });

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'agent_id': agentId,
      'agent_name': agentName,
      'permission_type': permissionType.name,
      'reason': reason,
      'status': status.name,
      'request_time': requestTime.toIso8601String(),
      if (processedTime != null) 
        'processed_time': processedTime!.toIso8601String(),
      if (expiryTime != null) 
        'expiry_time': expiryTime!.toIso8601String(),
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// 从 JSON 创建
  factory PermissionRequest.fromJson(Map<String, dynamic> json) {
    return PermissionRequest(
      id: json['id'],
      agentId: json['agent_id'],
      agentName: json['agent_name'],
      permissionType: PermissionType.values.firstWhere(
        (e) => e.name == json['permission_type'],
      ),
      reason: json['reason'],
      status: PermissionStatus.values.firstWhere(
        (e) => e.name == json['status'],
      ),
      requestTime: DateTime.parse(json['request_time']),
      processedTime: json['processed_time'] != null
          ? DateTime.parse(json['processed_time'])
          : null,
      expiryTime: json['expiry_time'] != null
          ? DateTime.parse(json['expiry_time'])
          : null,
      metadata: json['metadata'],
    );
  }

  /// 从数据库记录创建
  factory PermissionRequest.fromMap(Map<String, dynamic> map) {
    return PermissionRequest(
      id: map['id'],
      agentId: map['agent_id'],
      agentName: map['agent_name'],
      permissionType: PermissionType.values.firstWhere(
        (e) => e.name == map['permission_type'],
      ),
      reason: map['reason'] ?? '',
      status: PermissionStatus.values.firstWhere(
        (e) => e.name == map['status'],
      ),
      requestTime: DateTime.parse(map['request_time']),
      processedTime: map['processed_time'] != null
          ? DateTime.parse(map['processed_time'])
          : null,
      expiryTime: map['expiry_time'] != null
          ? DateTime.parse(map['expiry_time'])
          : null,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(map['metadata'])
          : null,
    );
  }

  /// 转换为数据库记录
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'agent_id': agentId,
      'agent_name': agentName,
      'permission_type': permissionType.name,
      'reason': reason,
      'status': status.name,
      'request_time': requestTime.toIso8601String(),
      if (processedTime != null) 
        'processed_time': processedTime!.toIso8601String(),
      if (expiryTime != null) 
        'expiry_time': expiryTime!.toIso8601String(),
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// 是否已过期
  bool get isExpired {
    if (expiryTime == null) return false;
    return DateTime.now().isAfter(expiryTime!);
  }

  /// 是否可用
  bool get isActive {
    return status == PermissionStatus.approved && !isExpired;
  }
}

/// 权限审核结果
class PermissionResult {
  /// 请求 ID
  final String requestId;

  /// 是否通过
  final bool approved;

  /// Agent ID
  final String agentId;

  /// Agent 名称
  final String agentName;

  /// 权限类型
  final PermissionType permissionType;

  /// 时间戳
  final DateTime timestamp;

  PermissionResult({
    required this.requestId,
    required this.approved,
    required this.agentId,
    required this.agentName,
    required this.permissionType,
    required this.timestamp,
  });
}

/// 权限管理服务
class PermissionService {
  final LocalStorageService _storageService;
  
  /// 等待处理的回调函数
  final Map<String, Function(bool)> _pendingCallbacks = {};

  /// 待审核请求通知流
  final StreamController<PermissionRequest> _pendingRequestController =
      StreamController<PermissionRequest>.broadcast();

  /// 待审核请求流（UI 监听此流弹出审核弹窗）
  Stream<PermissionRequest> get pendingRequestStream =>
      _pendingRequestController.stream;

  PermissionService(this._storageService);

  /// 初始化数据库表
  Future<void> initialize() async {
    final db = await _storageService.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS permission_requests (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        agent_name TEXT NOT NULL,
        permission_type TEXT NOT NULL,
        reason TEXT,
        status TEXT NOT NULL,
        request_time TEXT NOT NULL,
        processed_time TEXT,
        expiry_time TEXT,
        metadata TEXT
      )
    ''');
  }

  /// 请求权限
  Future<PermissionRequest> requestPermission({
    required String agentId,
    required String agentName,
    required PermissionType permissionType,
    required String reason,
    Map<String, dynamic>? metadata,
    Duration? validity,
  }) async {
    // 检查是否已有有效权限
    final existing = await _getActivePermission(agentId, permissionType);
    if (existing != null) {
      return existing;
    }

    // 创建新请求
    final request = PermissionRequest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      agentId: agentId,
      agentName: agentName,
      permissionType: permissionType,
      reason: reason,
      status: PermissionStatus.pending,
      requestTime: DateTime.now(),
      expiryTime: validity != null 
          ? DateTime.now().add(validity)
          : null,
      metadata: metadata,
    );

    // 保存到数据库
    final db = await _storageService.database;
    await db.insert('permission_requests', request.toMap());

    return request;
  }

  /// 强制请求权限并等待用户审核（不检查缓存，每次都弹窗）
  Future<PermissionResult> requestFreshPermissionAndWait({
    required String agentId,
    required String agentName,
    required PermissionType permissionType,
    required String reason,
    Map<String, dynamic>? metadata,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    // 1. 总是创建新的 PermissionRequest（不检查缓存）
    final request = PermissionRequest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      agentId: agentId,
      agentName: agentName,
      permissionType: permissionType,
      reason: reason,
      status: PermissionStatus.pending,
      requestTime: DateTime.now(),
      metadata: metadata,
    );

    // 2. 存入 DB
    final db = await _storageService.database;
    await db.insert('permission_requests', request.toMap());

    // 3. 通过 Stream 通知 UI 弹窗
    _pendingRequestController.add(request);

    // 4. 阻塞等待用户决策
    final approved = await waitForApproval(request.id, timeout: timeout);

    // 5. 返回 PermissionResult
    return PermissionResult(
      requestId: request.id,
      approved: approved,
      agentId: agentId,
      agentName: agentName,
      permissionType: permissionType,
      timestamp: DateTime.now(),
    );
  }

  /// 批准权限
  Future<void> approvePermission(String requestId) async {
    final db = await _storageService.database;
    await db.update(
      'permission_requests',
      {
        'status': PermissionStatus.approved.name,
        'processed_time': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [requestId],
    );

    // 触发回调
    final callback = _pendingCallbacks.remove(requestId);
    callback?.call(true);
  }

  /// 拒绝权限
  Future<void> rejectPermission(String requestId) async {
    final db = await _storageService.database;
    await db.update(
      'permission_requests',
      {
        'status': PermissionStatus.rejected.name,
        'processed_time': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [requestId],
    );

    // 触发回调
    final callback = _pendingCallbacks.remove(requestId);
    callback?.call(false);
  }

  /// 检查权限
  Future<bool> checkPermission({
    required String agentId,
    required PermissionType permissionType,
  }) async {
    final permission = await _getActivePermission(agentId, permissionType);
    return permission != null && permission.isActive;
  }

  /// 获取有效权限
  Future<PermissionRequest?> _getActivePermission(
    String agentId,
    PermissionType permissionType,
  ) async {
    final db = await _storageService.database;
    final results = await db.query(
      'permission_requests',
      where: 'agent_id = ? AND permission_type = ? AND status = ?',
      whereArgs: [
        agentId,
        permissionType.name,
        PermissionStatus.approved.name,
      ],
      orderBy: 'request_time DESC',
      limit: 1,
    );

    if (results.isEmpty) return null;

    final permission = PermissionRequest.fromMap(results.first);
    if (permission.isExpired) {
      // 标记为已过期
      await db.update(
        'permission_requests',
        {'status': PermissionStatus.expired.name},
        where: 'id = ?',
        whereArgs: [permission.id],
      );
      return null;
    }

    return permission;
  }

  /// 获取待处理的权限请求
  Future<List<PermissionRequest>> getPendingRequests() async {
    final db = await _storageService.database;
    final results = await db.query(
      'permission_requests',
      where: 'status = ?',
      whereArgs: [PermissionStatus.pending.name],
      orderBy: 'request_time DESC',
    );

    return results.map((map) => PermissionRequest.fromMap(map)).toList();
  }

  /// 获取所有权限请求
  Future<List<PermissionRequest>> getAllRequests({String? agentId}) async {
    final db = await _storageService.database;
    final results = await db.query(
      'permission_requests',
      where: agentId != null ? 'agent_id = ?' : null,
      whereArgs: agentId != null ? [agentId] : null,
      orderBy: 'request_time DESC',
    );

    return results.map((map) => PermissionRequest.fromMap(map)).toList();
  }

  /// 撤销权限
  Future<void> revokePermission({
    required String agentId,
    required PermissionType permissionType,
  }) async {
    final db = await _storageService.database;
    await db.update(
      'permission_requests',
      {
        'status': PermissionStatus.rejected.name,
        'processed_time': DateTime.now().toIso8601String(),
      },
      where: 'agent_id = ? AND permission_type = ? AND status = ?',
      whereArgs: [
        agentId,
        permissionType.name,
        PermissionStatus.approved.name,
      ],
    );
  }

  /// 等待权限决策
  Future<bool> waitForApproval(String requestId, {Duration? timeout}) async {
    final completer = Completer<bool>();
    
    _pendingCallbacks[requestId] = (approved) {
      if (!completer.isCompleted) {
        completer.complete(approved);
      }
    };

    // 设置超时
    if (timeout != null) {
      Future.delayed(timeout, () {
        if (!completer.isCompleted) {
          _pendingCallbacks.remove(requestId);
          completer.complete(false);
        }
      });
    }

    return completer.future;
  }

  /// 清理过期请求
  Future<void> cleanupExpiredRequests() async {
    final db = await _storageService.database;
    await db.update(
      'permission_requests',
      {'status': PermissionStatus.expired.name},
      where: 'status = ? AND expiry_time < ?',
      whereArgs: [
        PermissionStatus.approved.name,
        DateTime.now().toIso8601String(),
      ],
    );
  }
}
