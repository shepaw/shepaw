import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/agent_conversation_request.dart';
import '../config/app_config.dart';
import '../utils/http_client.dart';
import '../utils/exceptions.dart';

class ApiService {
  final String baseUrl;
  late HttpClientWrapper client;

  ApiService({String? baseUrl}) 
      : baseUrl = baseUrl ?? AppConfig.current.apiBaseUrl {
    client = HttpClientWrapper();
  }

  // ============================================
  // 用户 API
  // ============================================

  /// 用户登录
  Future<Map<String, dynamic>> login(String username, String avatar) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/users/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'avatar': avatar,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return {
        'user': User.fromJson(data['user']),
        'channels': (data['channels'] as List)
            .map((c) => Channel.fromJson(c))
            .toList(),
        'agents': (data['agents'] as List)
            .map((a) => Agent.fromJson(a))
            .toList(),
      };
    } else {
      throw Exception('登录失败: ${response.body}');
    }
  }

  // ============================================
  // Agent API
  // ============================================

  /// 获取所有 Agent
  Future<List<Agent>> getAgents() async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/agents'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['agents'] as List)
          .map((a) => Agent.fromJson(a))
          .toList();
    } else {
      throw Exception('获取 Agents 失败');
    }
  }

  /// 获取在线 Agent
  Future<List<Agent>> getOnlineAgents() async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/agents/online'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['agents'] as List)
          .map((a) => Agent.fromJson(a))
          .toList();
    } else {
      throw Exception('获取在线 Agents 失败');
    }
  }

  /// 注册新 Agent
  Future<Agent> registerAgent(Agent agent) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/agents/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(agent.toJson()),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Agent.fromJson(data['agent']);
    } else {
      throw Exception('注册 Agent 失败: ${response.body}');
    }
  }

  /// 更新 Agent
  Future<Agent> updateAgent(Agent agent) async {
    final response = await client.put(
      Uri.parse('$baseUrl/api/agents/${agent.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(agent.toJson()),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Agent.fromJson(data['agent']);
    } else {
      throw Exception('更新 Agent 失败: ${response.body}');
    }
  }

  /// 删除 Agent
  Future<void> deleteAgent(String agentId) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/api/agents/$agentId'),
    );

    if (response.statusCode != 200) {
      throw Exception('删除 Agent 失败: ${response.body}');
    }
  }

  // ============================================
  // 频道 API
  // ============================================

  /// 获取所有频道
  Future<List<Channel>> getChannels() async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/channels'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['channels'] as List)
          .map((c) => Channel.fromJson(c))
          .toList();
    } else {
      throw Exception('获取频道失败');
    }
  }

  /// 创建频道
  Future<Channel> createChannel(Channel channel) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/channels'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(channel.toJson()),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Channel.fromJson(data['channel']);
    } else {
      throw Exception('创建频道失败: ${response.body}');
    }
  }

  /// 创建私聊
  Future<Channel> createDM(String userId, String agentId) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/channels/dm'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'agentId': agentId,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Channel.fromJson(data['channel']);
    } else {
      throw Exception('创建私聊失败');
    }
  }

  /// 创建群聊
  Future<Channel> createGroup(
    String creatorId,
    String name,
    List<String> agentIds,
  ) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/channels/group'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'creatorId': creatorId,
        'name': name,
        'agentIds': agentIds,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Channel.fromJson(data['channel']);
    } else {
      throw Exception('创建群聊失败');
    }
  }

  /// 获取用户频道列表
  Future<List<Channel>> getUserChannels(String userId) async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/users/$userId/channels'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['channels'] as List)
          .map((c) => Channel.fromJson(c))
          .toList();
    } else {
      throw Exception('获取频道列表失败');
    }
  }

  // ============================================
  // 消息 API
  // ============================================

  /// 发送消息
  Future<Message> sendMessage({
    required String from,
    String? to,
    String? channelId,
    required String content,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'from': from,
        'to': to,
        'channelId': channelId,
        'content': content,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return Message.fromJson(data['message']);
    } else {
      throw Exception('发送消息失败');
    }
  }

  /// 获取消息历史
  Future<List<Message>> getMessages({
    String? channelId,
    int limit = 50,
  }) async {
    final uri = Uri.parse('$baseUrl/api/messages').replace(queryParameters: {
      if (channelId != null) 'channelId': channelId,
      'limit': limit.toString(),
    });

    final response = await client.get(uri);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['messages'] as List)
          .map((m) => Message.fromJson(m))
          .toList();
    } else {
      throw Exception('获取消息失败');
    }
  }

  /// 获取平台统计
  Future<Map<String, dynamic>> getStats() async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/stats'),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('获取统计失败');
    }
  }

  // ============================================
  // Agent 对话确认 API
  // ============================================

  /// 获取待确认的 Agent 对话请求
  Future<List<AgentConversationRequest>> getPendingApprovals(
      String userId) async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/users/$userId/pending-approvals'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data['requests'] as List)
          .map((r) => AgentConversationRequest.fromJson(r))
          .toList();
    } else {
      throw Exception('获取待确认请求失败');
    }
  }

  /// 批准 Agent 对话
  Future<void> approveConversation(String userId, String requestId) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/users/$userId/approve-conversation'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'request_id': requestId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('批准对话失败: ${response.body}');
    }
  }

  /// 拒绝 Agent 对话
  Future<void> rejectConversation(
    String userId,
    String requestId, {
    String? reason,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/users/$userId/reject-conversation'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'request_id': requestId,
        'reason': reason,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('拒绝对话失败: ${response.body}');
    }
  }

  void dispose() {
    client.close();
  }
}
