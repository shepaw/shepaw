import 'dart:async';
import '../models/remote_agent.dart';
import '../models/message.dart';
import 'acp_agent_connection.dart';

/// 协议路由器
/// 负责将消息路由到对应的协议处理器
class ProtocolRouter {
  /// ACP connection pool (keyed by agent ID)
  final Map<String, ACPAgentConnection> _acpConnections = {};

  ProtocolRouter();

  // ==================== 消息路由 ====================

  /// 路由消息到对应的协议处理器
  Future<void> routeMessage(RemoteAgent agent, Message message) async {
    switch (agent.protocol) {
      case ProtocolType.acp:
        await _handleACPMessage(agent, message);
        break;
      case ProtocolType.custom:
        await _handleCustomMessage(agent, message);
        break;
    }
  }

  /// 路由流式消息
  Stream<Message> routeStreamMessage(RemoteAgent agent, Message message) async* {
    switch (agent.protocol) {
      case ProtocolType.acp:
        yield* _handleACPStreamMessage(agent, message);
        break;
      case ProtocolType.custom:
        yield* _handleCustomStreamMessage(agent, message);
        break;
    }
  }

  // ==================== ACP 协议处理 ====================

  /// Get or create an ACP connection for the given agent.
  Future<ACPAgentConnection> _getOrCreateACPConnection(RemoteAgent agent) async {
    var connection = _acpConnections[agent.id];
    if (connection != null && connection.isConnected) {
      return connection;
    }

    connection = ACPAgentConnection(agentId: agent.id);
    _acpConnections[agent.id] = connection;

    // Build WebSocket URL
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
      pinnedFingerprint: (agent.metadata['noise_peer_fp'] as String?) ?? '',
    );
    return connection;
  }

  /// 处理 ACP 协议消息
  Future<void> _handleACPMessage(RemoteAgent agent, Message message) async {
    try {
      final connection = await _getOrCreateACPConnection(agent);
      await connection.sendChatMessage(
        taskId: message.id,
        sessionId: message.channelId ?? '',
        message: message.content,
        userId: message.from.id,
        messageId: message.id,
        systemPrompt: agent.metadata['system_prompt'] as String?,
      );
    } catch (e) {
      throw Exception('ACP message routing failed: $e');
    }
  }

  /// 处理 ACP 流式消息
  Stream<Message> _handleACPStreamMessage(RemoteAgent agent, Message message) async* {
    try {
      final connection = await _getOrCreateACPConnection(agent);
      final responseCompleter = Completer<String>();
      String content = '';

      connection.onTextContent = (data) {
        final chunk = data['content'] as String? ?? '';
        content += chunk;
      };

      connection.onTaskCompleted = (data) {
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(content);
        }
      };

      connection.onTaskError = (data) {
        if (!responseCompleter.isCompleted) {
          responseCompleter.completeError(
            Exception(data['message'] ?? 'Task error'),
          );
        }
      };

      await connection.sendChatMessage(
        taskId: message.id,
        sessionId: message.channelId ?? '',
        message: message.content,
        userId: message.from.id,
        messageId: message.id,
        systemPrompt: agent.metadata['system_prompt'] as String?,
      );

      final responseContent = await responseCompleter.future;

      yield Message(
        id: '${message.id}_response',
        from: MessageFrom(
          id: agent.id,
          type: 'agent',
          name: agent.name,
        ),
        channelId: message.channelId,
        type: MessageType.text,
        content: responseContent,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      throw Exception('ACP stream routing failed: $e');
    }
  }

  // ==================== 自定义协议处理 ====================

  Future<void> _handleCustomMessage(RemoteAgent agent, Message message) async {
    throw Exception('Custom protocol is not supported yet. Please use ACP protocol instead.');
  }

  Stream<Message> _handleCustomStreamMessage(RemoteAgent agent, Message message) async* {
    throw Exception('Custom protocol streaming is not supported yet. Please use ACP protocol instead.');
  }

  // ==================== 协议能力查询 ====================

  bool supportsStreaming(ProtocolType protocol) {
    switch (protocol) {
      case ProtocolType.acp:
        return true;
      case ProtocolType.custom:
        return false;
    }
  }

  bool supportsFileTransfer(ProtocolType protocol) {
    switch (protocol) {
      case ProtocolType.acp:
        return true;
      case ProtocolType.custom:
        return false;
    }
  }

  List<String> getProtocolCapabilities(ProtocolType protocol) {
    switch (protocol) {
      case ProtocolType.acp:
        return [
          'text_message',
          'streaming',
          'file_transfer',
          'bidirectional',
          'agent_discovery',
          'conversation_request',
          'interactive_ui',
        ];
      case ProtocolType.custom:
        return ['text_message'];
    }
  }

  // ==================== 协议验证 ====================

  bool validateAgentConfiguration(RemoteAgent agent) {
    switch (agent.protocol) {
      case ProtocolType.acp:
        return _validateACPConfiguration(agent);
      case ProtocolType.custom:
        return _validateCustomConfiguration(agent);
    }
  }

  bool _validateACPConfiguration(RemoteAgent agent) {
    if (agent.endpoint.isEmpty) return false;
    // ACP supports both ws:// endpoints and http:// endpoints (auto-converted)
    final uri = Uri.tryParse(agent.endpoint);
    if (uri == null) return false;
    return uri.scheme.startsWith('ws') || uri.scheme.startsWith('http');
  }

  bool _validateCustomConfiguration(RemoteAgent agent) {
    return agent.endpoint.isNotEmpty;
  }

  // ==================== 清理 ====================

  /// Disconnect all ACP connections
  void dispose() {
    for (final connection in _acpConnections.values) {
      connection.dispose();
    }
    _acpConnections.clear();
  }

  Exception createProtocolError(ProtocolType protocol, String message, dynamic error) {
    return Exception('${protocol.name.toUpperCase()} Protocol Error: $message - $error');
  }
}
