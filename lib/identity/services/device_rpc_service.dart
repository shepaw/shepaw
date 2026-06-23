import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../clis/shepaw/shepaw_cli.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/she_service.dart';
import '../models/device_role.dart';
import '../utils/device_rpc_policy.dart';
import 'account_identity_service.dart';
import 'sync_protocol_service.dart';

/// 跨自有设备的 RPC（在 Noise 加密 control 通道上）。
class DeviceRpcService {
  DeviceRpcService._();
  static final DeviceRpcService instance = DeviceRpcService._();

  static const _tag = 'DeviceRpc';
  static const _allowedMethods = {
    'cli.exec',
    'agents.list',
    'devices.ping',
    'sync.status',
    'messages.fetch',
    'agents.fetch',
  };

  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _uuid = const Uuid();

  /// 向指定 deviceId 的自有设备发送 RPC。
  Future<Map<String, dynamic>> call({
    required String targetDeviceId,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_allowedMethods.contains(method)) {
      throw ArgumentError('RPC method not allowed: $method');
    }

    final peerId = await _peerIdForDevice(targetDeviceId);
    if (peerId == null) {
      throw StateError('Device $targetDeviceId is not paired or offline');
    }

    final requestId = _uuid.v4();
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'device_rpc',
      'request_id': requestId,
      'method': method,
      'params': params ?? {},
    });

    final resp = await SyncProtocolService.instance.waitDeviceRpcResponse(
      requestId,
      timeout: timeout,
    );
    if (resp == null) throw StateError('RPC timeout');
    if (resp['error'] != null) throw StateError(resp['error'].toString());
    return Map<String, dynamic>.from(resp['result'] as Map? ?? {});
  }

  /// 在本机处理入站 RPC（仅自有设备域）。
  Future<Map<String, dynamic>> handleInbound({
    required String method,
    required Map<String, dynamic> params,
  }) async {
    if (!_allowedMethods.contains(method)) {
      return {'error': 'method_not_allowed'};
    }

    final localRole = await AccountIdentityService.instance.localDeviceRole();
    if (!DeviceRpcPolicy.receiverMayExecute(method, localRole)) {
      return {'error': 'rpc_receiver_not_allowed'};
    }

    switch (method) {
      case 'devices.ping':
        final local = await AccountIdentityService.instance.localDevice();
        return {
          'pong': true,
          'device_id': local?.deviceId,
          'role': local?.role.wireValue,
        };
      case 'agents.list':
        return await _agentsList(params);
      case 'cli.exec':
        return await _cliExec(params);
      case 'sync.status':
        return await _syncStatus();
      case 'messages.fetch':
        return await _messagesFetch(params);
      case 'agents.fetch':
        return await _agentsFetch(params);
      default:
        return {'error': 'unknown_method'};
    }
  }

  Future<Map<String, dynamic>> _agentsList(Map<String, dynamic> params) async {
    final status = params['status'] as String? ?? 'all';
    var agents = await _db.getAllRemoteAgents();
    if (status != 'all') {
      agents = agents.where((a) => a.status.name == status).toList();
    }
    return {
      'agents': agents
          .map((a) => {
                'id': a.id,
                'name': a.name,
                'status': a.status.name,
                'is_local': a.isLocal,
              })
          .toList(),
      'count': agents.length,
    };
  }

  Future<Map<String, dynamic>> _cliExec(Map<String, dynamic> params) async {
    final line = params['command'] as String? ?? '';
    if (line.isEmpty) return {'error': 'empty_command'};

    // 仅允许 shepaw 前缀；去掉前缀后 parse 为 namespace/subcommand/flags 较复杂 — 直接 split。
    final trimmed = line.trim();
    if (!trimmed.startsWith('shepaw ')) {
      return {'error': 'command_must_start_with_shepaw'};
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return {'error': 'invalid_command'};
    }

    final namespace = parts[1];
    final subcommand = parts.length > 2 && !parts[2].startsWith('--') ? parts[2] : '';
    final flags = <String, String>{};
    for (var i = 2; i < parts.length; i++) {
      if (parts[i].startsWith('--')) {
        final key = parts[i].substring(2);
        if (i + 1 < parts.length && !parts[i + 1].startsWith('--')) {
          flags[key] = parts[i + 1];
          i++;
        } else {
          flags[key] = '';
        }
      }
    }

    final resultJson = await ShepawCLI.instance.execute(
      {
        'namespace': namespace,
        if (subcommand.isNotEmpty) 'subcommand': subcommand,
        'flags': flags,
      },
      agentId: SheService.sheId,
    );

    try {
      return {'output': jsonDecode(resultJson)};
    } catch (_) {
      return {'output_raw': resultJson};
    }
  }

  Future<Map<String, dynamic>> _syncStatus() async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    final owned = await AccountIdentityService.instance.ownedDevices();
    final pendingEvents = await _db.countPendingOutbound();
    final pendingBlobs = await _db.countPendingBlobOutbound();
    return {
      'role': role.wireValue,
      'device_count': owned.length,
      'pending_events': pendingEvents,
      'pending_blobs': pendingBlobs,
    };
  }

  Future<Map<String, dynamic>> _messagesFetch(Map<String, dynamic> params) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary && role != DeviceRole.backup) {
      return {'error': 'not_storage_device'};
    }
    final messageId = params['message_id'] as String? ?? '';
    if (messageId.isEmpty) return {'error': 'missing_message_id'};
    final row = await _db.getMessageById(messageId, fetchRemote: false);
    if (row == null) return {'error': 'not_found'};
    return {'message': row};
  }

  Future<Map<String, dynamic>> _agentsFetch(Map<String, dynamic> params) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary && role != DeviceRole.backup) {
      return {'error': 'not_storage_device'};
    }
    final agentId = params['agent_id'] as String? ?? '';
    if (agentId.isEmpty) return {'error': 'missing_agent_id'};
    final row = await _db.getAgentRowById(agentId);
    if (row == null) return {'error': 'not_found'};
    return {'agent': row};
  }

  Future<String?> _peerIdForDevice(String deviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == deviceId) return p.id;
    }
    // 也允许 owned_devices 表中的 device_id 匹配
    final owned = await AccountIdentityService.instance.ownedDevices();
    for (final d in owned) {
      if (d.deviceId == deviceId) {
        for (final p in peers) {
          if (p.deviceId == deviceId) return p.id;
        }
      }
    }
    return null;
  }
}
