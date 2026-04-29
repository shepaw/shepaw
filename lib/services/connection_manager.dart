import 'dart:async';
import '../models/remote_agent.dart';
import '../models/message.dart';
import 'remote_agent_service.dart';
import 'acp_agent_connection.dart';
import 'logger_service.dart';
import 'peer_key_utils.dart';

/// 连接管理器
/// 负责管理远端助手的连接生命周期
class ConnectionManager {
  final RemoteAgentService _agentService;

  // ACP 连接池
  final Map<String, ACPAgentConnection> _acpConnections = {};

  // 消息流控制器
  final Map<String, StreamController<Message>> _messageControllers = {};

  // 心跳监控
  Timer? _heartbeatTimer;
  Duration heartbeatInterval = const Duration(seconds: 30);
  Duration heartbeatTimeout = const Duration(seconds: 90);

  // 重连配置
  final Map<String, int> _reconnectAttempts = {};
  final int maxReconnectAttempts = 5;
  final Duration reconnectDelay = const Duration(seconds: 5);

  ConnectionManager(this._agentService);

  // ==================== 连接管理 ====================

  /// 连接远端助手
  ///
  /// [agent] 要连接的助手
  ///
  /// Always uses ACP WebSocket connection.
  Future<void> connectAgent(RemoteAgent agent) async {
    if (agent.endpoint.isEmpty) {
      throw Exception('Agent endpoint is empty');
    }

    try {
      await _connectACP(agent);

      // 更新助手状态为在线
      await _agentService.registerAgentConnection(
        agent.token,
        endpoint: agent.endpoint,
      );

      // 重置重连计数
      _reconnectAttempts[agent.id] = 0;
    } catch (e) {
      await _agentService.markAgentError(agent.id);
      rethrow;
    }
  }

  /// 建立 ACP WebSocket 连接
  Future<void> _connectACP(RemoteAgent agent) async {
    try {
      final connection = ACPAgentConnection(agentId: agent.id);

      // 监听连接状态变化，实时更新 Agent 在线/离线状态
      connection.onConnectionStateChanged = (bool connected) {
        if (connected) {
          _agentService.updateHeartbeat(agent.id).catchError((_) {});
          LoggerService().info('ACP connection online: ${agent.name}', tag: 'Connection');
        } else {
          _agentService.disconnectAgent(agent.id).catchError((_) {});
          _acpConnections.remove(agent.id);
          LoggerService().info('ACP connection offline: ${agent.name}', tag: 'Connection');
        }
      };

      String wsUrl;
      if (agent.endpoint.startsWith('ws://') || agent.endpoint.startsWith('wss://')) {
        wsUrl = agent.endpoint;
      } else {
        wsUrl = agent.endpoint
            .replaceFirst('https://', 'wss://')
            .replaceFirst('http://', 'ws://');
        if (!wsUrl.contains('/acp/ws')) {
          wsUrl = wsUrl.endsWith('/') ? '${wsUrl}acp/ws' : '$wsUrl/acp/ws';
        }
      }

      await connection.connect(
        wsUrl,
        agent.token,
        targetAgentId: agent.metadata['target_agent_id'] as String?,
        // v2.1: pinned peer fingerprint from the original pairing URL.
        // Stored in metadata by `AddRemoteAgentScreen._connectToAgent` —
        // required for the Noise handshake to pin the agent's identity.
        pinnedFingerprint: (agent.metadata['noise_peer_fp'] as String?) ?? '',
        cachedPeerStaticPublicKey: decodeCachedPeerPublicKey(
          agent.metadata['cached_peer_static_public_key'],
        ),
      );
      _acpConnections[agent.id] = connection;

      // Create message stream controller
      _messageControllers[agent.id] = StreamController<Message>.broadcast();
    } catch (e) {
      throw Exception('ACP connection failed: $e');
    }
  }

  /// 断开助手连接
  Future<void> disconnectAgent(String agentId) async {
    // 关闭 ACP 连接
    if (_acpConnections.containsKey(agentId)) {
      _acpConnections[agentId]?.dispose();
      _acpConnections.remove(agentId);
    }

    // 关闭消息流
    if (_messageControllers.containsKey(agentId)) {
      await _messageControllers[agentId]?.close();
      _messageControllers.remove(agentId);
    }

    // 更新助手状态
    await _agentService.disconnectAgent(agentId);

    // 清除重连计数
    _reconnectAttempts.remove(agentId);
  }

  /// v2.1: ask the remote agent to remove this device from its allowlist,
  /// then disconnect locally. Called by the UI right before deleting the
  /// RemoteAgent record, so the agent host doesn't end up with a stale
  /// authorized-peer entry that the user never intended to keep.
  ///
  /// Best-effort — if there's no live connection or the unregister RPC
  /// can't be delivered, we fall through to the normal disconnect path
  /// and the user's local delete still proceeds. Raising an error here
  /// would be user-hostile: the intent was "forget this agent".
  Future<void> unregisterAndDisconnect(String agentId) async {
    final conn = _acpConnections[agentId];
    if (conn != null) {
      try {
        await conn.unregisterSelfFromAgent();
      } catch (e) {
        LoggerService().warning(
          'unregisterSelfFromAgent failed, proceeding with local delete: $e',
          tag: 'ConnectionManager',
        );
      }
    }
    await disconnectAgent(agentId);
  }

  /// 重连助手
  Future<void> reconnectAgent(String agentId) async {
    final agent = await _agentService.getAgentById(agentId);
    if (agent == null) {
      throw Exception('Agent not found: $agentId');
    }

    // 检查重连次数
    final attempts = _reconnectAttempts[agentId] ?? 0;
    if (attempts >= maxReconnectAttempts) {
      await _agentService.markAgentError(agentId);
      throw Exception('Max reconnect attempts reached for agent: $agentId');
    }

    // 增加重连计数
    _reconnectAttempts[agentId] = attempts + 1;

    // 先断开现有连接
    await disconnectAgent(agentId);

    // 等待一段时间后重连
    await Future.delayed(reconnectDelay);

    // 尝试重新连接
    await connectAgent(agent);
  }

  // ==================== 消息收发 ====================

  /// 发送消息给助手
  ///
  /// [agentId] 助手 ID
  /// [message] 要发送的消息
  Future<void> sendMessage(String agentId, Message message) async {
    final agent = await _agentService.getAgentById(agentId);
    if (agent == null) {
      throw Exception('Agent not found: $agentId');
    }

    if (!agent.isOnline) {
      throw Exception('Agent is not online: $agentId');
    }

    try {
      // ACP connections are managed separately; this is a placeholder
      // for direct message sending via the connection manager.
      final connection = _acpConnections[agentId];
      if (connection == null || !connection.isConnected) {
        throw Exception('ACP connection not found for agent: $agentId');
      }
      await connection.sendChatMessage(
        taskId: message.id,
        sessionId: message.channelId ?? '',
        message: message.content,
        userId: message.from.id,
        messageId: message.id,
        systemPrompt: agent.metadata['system_prompt'] as String?,
      );
    } catch (e) {
      await _agentService.markAgentError(agentId);
      rethrow;
    }
  }

  /// 接收来自助手的消息流
  ///
  /// [agentId] 助手 ID
  ///
  /// 返回消息流
  Stream<Message> receiveMessages(String agentId) {
    final controller = _messageControllers[agentId];
    if (controller == null) {
      throw Exception('Message stream not found for agent: $agentId');
    }

    return controller.stream;
  }

  // ==================== 连接错误处理 ====================

  /// 处理连接错误
  void _handleConnectionError(String agentId, dynamic error) {
    // 标记助手为错误状态
    _agentService.markAgentError(agentId);

    // 尝试重连
    reconnectAgent(agentId).catchError((e) {
      // 重连失败，忽略错误
    });
  }

  /// 处理连接关闭
  void _handleConnectionClosed(String agentId) {
    // 断开连接
    disconnectAgent(agentId).catchError((e) {
      // 断开失败，忽略错误
    });

    // 尝试重连
    reconnectAgent(agentId).catchError((e) {
      // 重连失败，忽略错误
    });
  }

  // ==================== 心跳监控 ====================

  /// 启动心跳监控
  void startHeartbeatMonitor() {
    stopHeartbeatMonitor();

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      checkAgentHeartbeats();
    });
  }

  /// 停止心跳监控
  void stopHeartbeatMonitor() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 检查所有助手的心跳
  void checkAgentHeartbeats() {
    _agentService.handleHeartbeatTimeouts(
      timeoutDuration: heartbeatTimeout,
    ).then((value) {
      // 心跳检查完成
    }).catchError((e) {
      // 心跳检查失败，忽略错误
    });
  }

  // ==================== 连接状态查询 ====================

  /// 检查助手是否已连接
  bool isConnected(String agentId) {
    return _acpConnections.containsKey(agentId);
  }

  /// 获取所有已连接的助手 ID
  List<String> getConnectedAgentIds() {
    return _acpConnections.keys.toList();
  }

  /// 获取连接统计信息
  Map<String, dynamic> getConnectionStatistics() {
    return {
      'acp_connections': _acpConnections.length,
      'total_connections': _acpConnections.length,
      'message_streams': _messageControllers.length,
    };
  }

  // ==================== 清理 ====================

  /// 断开所有连接
  Future<void> disconnectAll() async {
    final agentIds = getConnectedAgentIds();
    for (final agentId in agentIds) {
      await disconnectAgent(agentId);
    }
  }

  /// 销毁连接管理器
  Future<void> dispose() async {
    stopHeartbeatMonitor();
    await disconnectAll();
    _reconnectAttempts.clear();
  }
}
