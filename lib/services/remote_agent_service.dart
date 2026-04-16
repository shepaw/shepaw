import 'package:uuid/uuid.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';
import 'local_llm_agent_service.dart';
import 'logger_service.dart';
import 'token_service.dart';
import 'acp_agent_connection.dart';
import 'chat_service.dart';
import 'she_service.dart';

/// Agent 重复异常
class AgentDuplicateException implements Exception {
  final String message;
  final RemoteAgent existingAgent;

  AgentDuplicateException(this.message, {required this.existingAgent});

  @override
  String toString() => message;
}

/// 远端助手服务
/// 负责远端助手的生命周期管理
class RemoteAgentService {
  final LocalDatabaseService _databaseService;
  final TokenService _tokenService;
  final Uuid _uuid = const Uuid();

  RemoteAgentService(this._databaseService, this._tokenService);

  // ==================== Token 管理 ====================

  /// 生成新的 Token
  Future<String> generateToken() async {
    return await _tokenService.generateUniqueToken();
  }

  /// 验证 Token
  Future<RemoteAgent?> verifyToken(String token) async {
    return await _tokenService.verifyToken(token);
  }

  /// 为指定 Agent 重新生成 Token
  Future<String> regenerateToken(String agentId) async {
    return await _tokenService.regenerateToken(agentId);
  }

  // ==================== Agent CRUD 操作 ====================

  /// 创建新的远端助手
  ///
  /// [name] 助手显示名称
  /// [protocol] 协议类型 (acp, custom)
  /// [connectionType] 连接类型 (websocket, http)
  /// [endpoint] 远端端点 URL（可选，可以在连接时提供）
  /// [bio] 助手描述（可选）
  /// [avatar] 助手头像（可选，默认 🤖）
  /// [capabilities] 能力列表（可选）
  /// [metadata] 元数据（可选）
  ///
  /// 返回创建的 [RemoteAgent] 对象
  Future<RemoteAgent> createAgent({
    required String name,
    required ProtocolType protocol,
    required ConnectionType connectionType,
    String endpoint = '',
    String? bio,
    String avatar = '🤖',
    List<String> capabilities = const [],
    Map<String, dynamic> metadata = const {},
    AgentStatus? initialStatus,
  }) async {
    // 检查 endpoint + agentId 是否已存在（endpoint 非空时）
    if (endpoint.isNotEmpty) {
      // 从 metadata 中提取 target_agent_id
      final targetAgentId = metadata['target_agent_id'] as String?;
      final existing = await _databaseService.getRemoteAgentByEndpointAndAgentId(
        endpoint,
        agentId: targetAgentId,
      );
      if (existing != null) {
        throw AgentDuplicateException(
          '已存在相同 Endpoint 和 Agent ID 的 Agent「${existing.name}」',
          existingAgent: existing,
        );
      }
    }

    // 生成唯一 ID 和 Token
    final id = _uuid.v4();
    final token = await generateToken();
    final now = DateTime.now().millisecondsSinceEpoch;

    final agent = RemoteAgent(
      id: id,
      name: name,
      avatar: avatar,
      bio: bio,
      token: token,
      endpoint: endpoint,
      protocol: protocol,
      connectionType: connectionType,
      status: initialStatus ?? AgentStatus.offline,
      capabilities: capabilities,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );

    await _databaseService.createRemoteAgent(agent);
    return agent;
  }

  /// 使用已有 Token 创建远端助手连接
  ///
  /// 用于连接到已存在的远端 Agent
  ///
  /// [name] 助手显示名称
  /// [protocol] 协议类型
  /// [connectionType] 连接类型
  /// [endpoint] 远端端点 URL
  /// [token] 远端提供的认证 Token
  /// [bio] 助手描述（可选）
  /// [avatar] 助手头像（可选，默认 🤖）
  /// [capabilities] 能力列表（可选）
  /// [metadata] 元数据（可选）
  ///
  /// 返回创建的 [RemoteAgent] 对象
  Future<RemoteAgent> createAgentWithToken({
    required String name,
    required ProtocolType protocol,
    required ConnectionType connectionType,
    required String endpoint,
    required String token,
    String? bio,
    String avatar = '🤖',
    List<String> capabilities = const [],
    Map<String, dynamic> metadata = const {},
  }) async {
    // 检查 endpoint + agentId 是否已存在
    if (endpoint.isNotEmpty) {
      // 从 metadata 中提取 target_agent_id
      final targetAgentId = metadata['target_agent_id'] as String?;
      final existingByEndpoint = await _databaseService.getRemoteAgentByEndpointAndAgentId(
        endpoint,
        agentId: targetAgentId,
      );
      if (existingByEndpoint != null) {
        throw AgentDuplicateException(
          '已存在相同 Endpoint 和 Agent ID 的 Agent「${existingByEndpoint.name}」',
          existingAgent: existingByEndpoint,
        );
      }
    }

    // 生成唯一 ID
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    final agent = RemoteAgent(
      id: id,
      name: name,
      avatar: avatar,
      bio: bio,
      token: token, // 使用提供的 Token
      endpoint: endpoint,
      protocol: protocol,
      connectionType: connectionType,
      status: AgentStatus.offline, // 初始状态为离线
      capabilities: capabilities,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );

    await _databaseService.createRemoteAgent(agent);
    return agent;
  }

  /// 更新远端助手
  Future<void> updateAgent(RemoteAgent agent) async {
    final updatedAgent = agent.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _databaseService.updateRemoteAgent(updatedAgent);
  }

  /// 删除远端助手
  Future<void> deleteAgent(String agentId) async {
    await _databaseService.deleteRemoteAgent(agentId);
  }

  // ==================== 查询操作 ====================

  /// 获取所有远端助手
  Future<List<RemoteAgent>> getAllAgents() async {
    return await _databaseService.getAllRemoteAgents();
  }

  /// 根据 ID 获取远端助手
  Future<RemoteAgent?> getAgentById(String agentId) async {
    return await _databaseService.getRemoteAgentById(agentId);
  }

  /// 根据 Token 获取远端助手
  Future<RemoteAgent?> getAgentByToken(String token) async {
    return await _databaseService.getRemoteAgentByToken(token);
  }

  /// 获取所有在线的远端助手
  Future<List<RemoteAgent>> getOnlineAgents() async {
    return await _databaseService.getOnlineRemoteAgents();
  }

  /// 根据协议类型获取助手
  Future<List<RemoteAgent>> getAgentsByProtocol(ProtocolType protocol) async {
    final allAgents = await getAllAgents();
    return allAgents.where((agent) => agent.protocol == protocol).toList();
  }

  /// 根据状态获取助手
  Future<List<RemoteAgent>> getAgentsByStatus(AgentStatus status) async {
    final allAgents = await getAllAgents();
    return allAgents.where((agent) => agent.status == status).toList();
  }

  // ==================== 连接注册 ====================

  /// 注册远端助手连接
  ///
  /// 当远端助手首次连接时调用此方法
  ///
  /// [token] 助手的认证 Token
  /// [endpoint] 实际的连接端点（可选，如果创建时未提供）
  /// [clientInfo] 客户端信息（可选，存储在 metadata 中）
  ///
  /// 返回连接成功的 [RemoteAgent]，如果 Token 无效返回 null
  Future<RemoteAgent?> registerAgentConnection(
    String token, {
    String? endpoint,
    Map<String, dynamic>? clientInfo,
  }) async {
    // 验证 Token
    final agent = await verifyToken(token);
    if (agent == null) {
      return null;
    }

    // 更新连接信息
    final now = DateTime.now().millisecondsSinceEpoch;
    final metadata = Map<String, dynamic>.from(agent.metadata);

    if (clientInfo != null) {
      metadata['client_info'] = clientInfo;
    }

    final updatedAgent = agent.copyWith(
      status: AgentStatus.online,
      connectedAt: now,
      lastHeartbeat: now,
      endpoint: endpoint ?? agent.endpoint,
      metadata: metadata,
      updatedAt: now,
    );

    await _databaseService.updateRemoteAgent(updatedAgent);
    return updatedAgent;
  }

  /// 更新心跳
  ///
  /// 定期调用以表示助手仍然在线
  Future<void> updateHeartbeat(String agentId) async {
    await _databaseService.updateRemoteAgentHeartbeat(agentId);
  }

  /// 断开助手连接
  ///
  /// 将助手状态设置为离线
  Future<void> disconnectAgent(String agentId) async {
    await _databaseService.updateRemoteAgentStatus(agentId, 'offline');
  }

  /// 标记助手为错误状态
  Future<void> markAgentError(String agentId) async {
    await _databaseService.updateRemoteAgentStatus(agentId, 'error');
  }

  /// 重置助手为离线状态（从错误恢复）
  Future<void> resetAgentStatus(String agentId) async {
    await _databaseService.updateRemoteAgentStatus(agentId, 'offline');
  }

  // ==================== 心跳监控 ====================

  /// 检查 Agent 的健康状态
  ///
  /// 通过调用 Agent 的 health 端点来检查其是否在线
  /// 如果健康检查成功，自动将 Agent 标记为在线
  /// 如果健康检查失败，将 Agent 标记为离线
  ///
  /// [agentId] 要检查的 Agent ID
  /// [timeout] 请求超时时间（默认 5 秒）
  ///
  /// 返回 true 表示 Agent 在线，false 表示离线
  Future<bool> checkAgentHealth(
    String agentId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {

    final agent = await getAgentById(agentId);
    if (agent == null) {
      LoggerService().error('Agent($agentId) 不存在', tag: 'RemoteAgent');
      return false;
    }

    // 本地 agent 不依赖远端 endpoint，跳过健康检查
    if (LocalLLMAgentService.instance.isLocalAgent(agent)) {
      return true;
    }


    // 检查 endpoint 是否有效
    if (agent.endpoint.trim().isEmpty) {
      LoggerService().error('Endpoint 为空，跳过健康检查', tag: 'RemoteAgent');
      return false;
    }

    // 如果已经是在线状态且有最近的心跳记录（60秒内），直接返回 true
    final now = DateTime.now().millisecondsSinceEpoch;
    if (agent.isOnline &&
        agent.lastHeartbeat != null &&
        now - agent.lastHeartbeat! < 60000) {
      LoggerService().info('Agent 已在线且心跳有效 (最近心跳: ${DateTime.fromMillisecondsSinceEpoch(agent.lastHeartbeat!)})', tag: 'RemoteAgent');
      return true;
    }

    try {
      // 1. Try to ping via the existing ChatService connection (avoids
      //    creating a throwaway WebSocket that immediately disconnects).
      final chatService = ChatService();
      final alive = await chatService.pingAgent(agentId);
      if (alive) {
        LoggerService().info('健康检查成功 (existing connection ping)', tag: 'RemoteAgent');
        final now = DateTime.now().millisecondsSinceEpoch;
        final updatedAgent = agent.copyWith(
          status: AgentStatus.online,
          lastHeartbeat: now,
          connectedAt: agent.connectedAt ?? now,
          updatedAt: now,
        );
        await _databaseService.updateRemoteAgent(updatedAgent);
        return true;
      }

      // 2. No existing connection — open a temporary one to verify
      //    the agent is reachable.
      String wsUrl;
      final endpoint = agent.endpoint.trim();
      if (endpoint.startsWith('ws://') || endpoint.startsWith('wss://')) {
        wsUrl = endpoint;
      } else {
        wsUrl = endpoint
            .replaceFirst('https://', 'wss://')
            .replaceFirst('http://', 'ws://');
        if (!wsUrl.contains('/acp/ws')) {
          wsUrl = wsUrl.endsWith('/') ? '${wsUrl}acp/ws' : '$wsUrl/acp/ws';
        }
      }

      // For local agents accessed externally, the endpoint is a bare
      // ws://host:port — don't append /acp/ws.
      // The targetAgentId tells connect() to add ?agentId=yyy to the URL.
      final targetAgentId = agent.metadata['target_agent_id'] as String?;

      LoggerService().debug('WebSocket URL: $wsUrl', tag: 'RemoteAgent');
      LoggerService().info('通过临时 WebSocket ping 检查健康状态...', tag: 'RemoteAgent');

      final connection = ACPAgentConnection(
        agentId: agent.id,
        autoReconnect: false,
      );

      try {
        // Wrap both connect and ping in a single shared timeout budget.
        // Using separate .timeout() on each would restart the clock after
        // connect() finishes, making the total wait up to 2× the budget.
        final bool healthy = await Future(() async {
          await connection.connect(wsUrl, agent.token, targetAgentId: targetAgentId);
          final pingResponse = await connection.ping();
          return pingResponse.isSuccess;
        }).timeout(timeout);

        if (healthy) {
          LoggerService().info('健康检查成功 (temporary ping)', tag: 'RemoteAgent');

          final now = DateTime.now().millisecondsSinceEpoch;
          final updatedAgent = agent.copyWith(
            status: AgentStatus.online,
            lastHeartbeat: now,
            connectedAt: agent.connectedAt ?? now,
            updatedAt: now,
          );

          await _databaseService.updateRemoteAgent(updatedAgent);
          return true;
        } else {
          LoggerService().error('健康检查失败 (ping error)', tag: 'RemoteAgent');
          await disconnectAgent(agentId);
          return false;
        }
      } finally {
        connection.dispose();
      }
    } catch (e) {
      // 503 means the channel tunnel is not yet online (the local agent hasn't
      // connected yet), not that the remote agent itself is down.  Treat it as
      // "temporarily unavailable" and preserve the current status rather than
      // marking the agent offline.
      final msg = e.toString();
      if (msg.contains('503') || msg.contains('502') ||
          msg.contains('ServiceUnavailable') || msg.contains('not upgraded')) {
        LoggerService().warning(
          '健康检查跳过 (隧道未就绪，保留当前状态): ${agent.name}',
          tag: 'RemoteAgent',
        );
        return agent.isOnline; // keep whatever the last known status was
      }
      LoggerService().error('健康检查失败 (${agent.name})', tag: 'RemoteAgent', error: e);
      await disconnectAgent(agentId);
      return false;
    }
  }

  /// 检查所有 Agent 的健康状态
  ///
  /// 适用于应用启动时或定期刷新 Agent 状态
  ///
  /// [timeout] 每个 Agent 检查的超时时间
  ///
  /// 返回在线的 Agent 数量
  Future<int> checkAllAgentsHealth({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final allAgents = await getAllAgents();

    final results = await Future.wait(
      allAgents.map((agent) => checkAgentHealth(agent.id, timeout: timeout)),
      eagerError: false,
    );

    return results.where((online) => online).length;
  }

  /// 检查所有助手的心跳超时
  ///
  /// [timeoutDuration] 心跳超时时长（默认 90 秒）
  ///
  /// 返回超时的助手列表
  Future<List<RemoteAgent>> checkHeartbeatTimeouts({
    Duration timeoutDuration = const Duration(seconds: 90),
  }) async {
    final onlineAgents = await getOnlineAgents();
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeoutAgents = <RemoteAgent>[];

    for (final agent in onlineAgents) {
      if (agent.lastHeartbeat == null) {
        // 如果没有心跳记录，检查连接时间
        if (agent.connectedAt != null &&
            now - agent.connectedAt! > timeoutDuration.inMilliseconds) {
          timeoutAgents.add(agent);
        }
      } else {
        // 检查最后心跳时间
        if (now - agent.lastHeartbeat! > timeoutDuration.inMilliseconds) {
          timeoutAgents.add(agent);
        }
      }
    }

    return timeoutAgents;
  }

  /// 处理心跳超时
  ///
  /// 将超时的助手标记为离线
  Future<void> handleHeartbeatTimeouts({
    Duration timeoutDuration = const Duration(seconds: 90),
  }) async {
    final timeoutAgents = await checkHeartbeatTimeouts(
      timeoutDuration: timeoutDuration,
    );

    for (final agent in timeoutAgents) {
      await disconnectAgent(agent.id);
    }
  }

  // ==================== 统计信息 ====================

  /// 获取助手统计信息
  Future<Map<String, dynamic>> getAgentStatistics() async {
    final allAgents = await getAllAgents();
    final onlineAgents = allAgents.where((a) => a.isOnline).toList();
    final offlineAgents = allAgents.where((a) => a.isOffline).toList();
    final errorAgents = allAgents.where((a) => a.hasError).toList();

    return {
      'total': allAgents.length,
      'online': onlineAgents.length,
      'offline': offlineAgents.length,
      'error': errorAgents.length,
      'by_protocol': {
        'acp': allAgents.where((a) => a.protocol == ProtocolType.acp).length,
        'custom': allAgents.where((a) => a.protocol == ProtocolType.custom).length,
      },
      'by_connection_type': {
        'websocket': allAgents.where((a) => a.connectionType == ConnectionType.websocket).length,
        'http': allAgents.where((a) => a.connectionType == ConnectionType.http).length,
      },
    };
  }

  /// 获取助手详细信息（包括统计）
  Future<Map<String, dynamic>> getAgentDetails(String agentId) async {
    final agent = await getAgentById(agentId);
    if (agent == null) {
      throw Exception('Agent not found: $agentId');
    }

    // 计算在线时长
    int? onlineMs;
    if (agent.isOnline && agent.connectedAt != null) {
      onlineMs = DateTime.now().millisecondsSinceEpoch - agent.connectedAt!;
    }

    // 计算最后活跃时间
    int? lastActiveMs;
    if (agent.lastHeartbeat != null) {
      lastActiveMs = DateTime.now().millisecondsSinceEpoch - agent.lastHeartbeat!;
    }

    return {
      'agent': agent,
      'online_duration_ms': onlineMs,
      'last_active_ms': lastActiveMs,
    };
  }

  /// 确保内置守护 Agent She 存在（代理到 SheService）
  Future<void> ensureSheExists() => SheService.instance.ensureSheExists();
}
