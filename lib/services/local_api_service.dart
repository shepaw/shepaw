import 'package:uuid/uuid.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/agent_conversation_request.dart';
import 'local_database_service.dart';
import 'local_file_storage_service.dart';
import 'logger_service.dart';

/// 本地化 API 服务 - 替代网络请求，使用本地数据库
class LocalApiService {
  static final LocalApiService _instance = LocalApiService._internal();
  factory LocalApiService() => _instance;
  LocalApiService._internal();

  final _db = LocalDatabaseService();
  final _storage = LocalFileStorageService();
  final _uuid = const Uuid();

  // 当前登录用户ID（简化版，实际应该从 AuthService 获取）
  String _currentUserId = 'local_user_001';

  String get currentUserId => _currentUserId;
  set currentUserId(String id) => _currentUserId = id;

  // ==================== 用户认证 ====================

  /// 用户登录
  Future<Map<String, dynamic>> login(String username, String avatar) async {
    try {
      // 设置当前用户ID
      _currentUserId = _uuid.v4();

      // 返回用户信息、频道和agents
      final channels = await getChannels();
      final agents = await getAgents();

      return {
        'user': {'id': _currentUserId, 'username': username, 'avatar': avatar},
        'channels': channels,
        'agents': agents,
      };
    } catch (e) {
      LoggerService().error('Login failed', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  // ==================== Agent 管理 ====================

  /// 获取所有 Agent（带实时状态检查）
  Future<List<Agent>> getAgents() async {
    try {
      final agents = await _db.getAllAgents();
      
      // 异步更新所有 Agent 的实时状态
      final updatedAgents = await Future.wait(
        agents.map((agent) => _checkAndUpdateAgentStatus(agent)),
      );
      
      return updatedAgents;
    } catch (e) {
      LoggerService().error('Failed to get agent list', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 检查并更新 Agent 的实时状态
  Future<Agent> _checkAndUpdateAgentStatus(Agent agent) async {
    // 直接信任数据库中的状态
    // 远端助手的状态由 RemoteAgentService.checkAgentHealth 管理
    return agent;
  }

  /// 列出所有 Agent (别名)
  Future<List<Agent>> listAgents() async {
    return getAgents();
  }

  /// 根据 ID 获取 Agent
  Future<Agent?> getAgentById(String id) async {
    try {
      return await _db.getAgentById(id);
    } catch (e) {
      LoggerService().error('Failed to get agent', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 创建 Agent
  Future<Agent> createAgent(Agent agent) async {
    try {
      // 如果没有 ID，生成一个
      final agentToCreate = agent.id.isEmpty
          ? agent.copyWith(id: _uuid.v4())
          : agent;

      await _db.createAgent(agentToCreate, _currentUserId);
      return agentToCreate;
    } catch (e) {
      LoggerService().error('Failed to create agent', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 更新 Agent
  Future<Agent> updateAgent(Agent agent) async {
    try {
      await _db.updateAgent(agent);
      return agent;
    } catch (e) {
      LoggerService().error('Failed to update agent', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 删除 Agent
  Future<void> deleteAgent(String id) async {
    try {
      // 删除 Agent 相关的资源文件
      final agent = await _db.getAgentById(id);
      if (agent != null && agent.avatar.isNotEmpty) {
        await _storage.deleteImage(agent.avatar);
      }

      await _db.deleteAgent(id);
    } catch (e) {
      LoggerService().error('Failed to delete agent', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  // ==================== Channel 管理 ====================

  /// 获取所有 Channel
  Future<List<Channel>> getChannels() async {
    try {
      final channels = await _db.getAllChannels();
      
      // 填充最后一条消息信息
      for (int i = 0; i < channels.length; i++) {
        final messages = await _db.getChannelMessages(channels[i].id, limit: 1);
        if (messages.isNotEmpty) {
          final lastMsg = messages.first;
          channels[i] = channels[i].copyWith(
            lastMessage: lastMsg['content'] as String,
            lastMessageTime: DateTime.parse(lastMsg['created_at'] as String),
            unreadCount: await _getUnreadCount(channels[i].id),
          );
        }
      }
      
      return channels;
    } catch (e) {
      LoggerService().error('Failed to get channel list', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 根据 ID 获取 Channel
  Future<Channel?> getChannelById(String id) async {
    try {
      return await _db.getChannelById(id);
    } catch (e) {
      LoggerService().error('Failed to get channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 创建 Channel
  Future<Channel> createChannel(Channel channel) async {
    try {
      final channelToCreate = channel.id.isEmpty
          ? channel.copyWith(id: _uuid.v4())
          : channel;

      await _db.createChannel(channelToCreate, _currentUserId);
      return channelToCreate;
    } catch (e) {
      LoggerService().error('Failed to create channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 更新 Channel
  Future<Channel> updateChannel(Channel channel) async {
    try {
      await _db.updateChannel(channel);
      return channel;
    } catch (e) {
      LoggerService().error('Failed to update channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 删除 Channel
  Future<void> deleteChannel(String id) async {
    try {
      // 删除 Channel 相关的资源文件
      final channel = await _db.getChannelById(id);
      if (channel != null && channel.avatar != null) {
        await _storage.deleteImage(channel.avatar!);
      }

      await _db.deleteChannel(id);
    } catch (e) {
      LoggerService().error('Failed to delete channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 创建私聊频道
  Future<Channel> createDM(String userId, String agentId) async {
    try {
      // 检查是否已存在DM频道
      final existingChannels = await getChannels();
      final existingDM = existingChannels.where((c) =>
        c.type == 'dm' &&
        c.memberIds.contains(userId) &&
        c.memberIds.contains(agentId)
      ).firstOrNull;

      if (existingDM != null) {
        return existingDM;
      }

      // 获取agent信息
      final agent = await getAgentById(agentId);

      final channel = Channel.withMemberIds(
        id: _uuid.v4(),
        name: agent?.name ?? 'Direct Message',
        description: 'Direct message with ${agent?.name}',
        type: 'dm',
        memberIds: [userId, agentId],
        isPrivate: true,
      );

      await createChannel(channel);
      return channel;
    } catch (e) {
      LoggerService().error('Failed to create DM channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 创建群聊频道
  Future<Channel> createGroup(String userId, String name, List<String> agentIds) async {
    try {
      final channel = Channel.withMemberIds(
        id: _uuid.v4(),
        name: name,
        description: 'Group chat',
        type: 'group',
        memberIds: [userId, ...agentIds],
        isPrivate: false,
      );

      await createChannel(channel);
      return channel;
    } catch (e) {
      LoggerService().error('Failed to create group channel', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 获取用户的频道列表
  Future<List<Channel>> getUserChannels(String userId) async {
    try {
      final allChannels = await getChannels();
      // 过滤出用户参与的频道
      return allChannels.where((c) => c.memberIds.contains(userId)).toList();
    } catch (e) {
      LoggerService().error('Failed to get user channel list', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 添加 Channel 成员
  Future<void> addChannelMember(String channelId, String agentId) async {
    try {
      await _db.addChannelMember(channelId, agentId);
    } catch (e) {
      LoggerService().error('Failed to add channel member', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 移除 Channel 成员
  Future<void> removeChannelMember(String channelId, String agentId) async {
    try {
      await _db.removeChannelMember(channelId, agentId);
    } catch (e) {
      LoggerService().error('Failed to remove channel member', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  // ==================== 消息管理 ====================

  /// 发送消息
  Future<Message> sendMessage({
    String? from,
    String? to,
    String? channelId,
    required String content,
    String? replyToId,
  }) async {
    try {
      final messageId = _uuid.v4();
      final now = DateTime.now();
      final senderId = from ?? _currentUserId;

      // 如果没有指定channelId但指定了to，尝试创建或查找DM频道
      String targetChannelId = channelId ?? '';
      if (targetChannelId.isEmpty && to != null) {
        final dmChannel = await createDM(senderId, to);
        targetChannelId = dmChannel.id;
      }

      if (targetChannelId.isEmpty) {
        throw Exception('必须指定 channelId 或 to 参数');
      }

      await _db.createMessage(
        id: messageId,
        channelId: targetChannelId,
        senderId: senderId,
        senderType: 'user',
        senderName: 'Me',
        content: content,
        replyToId: replyToId,
      );

      // 触发 Agent 响应（异步执行，不阻塞消息发送）
      _triggerAgentResponse(targetChannelId, content).catchError((e) {
        LoggerService().error('Failed to trigger agent response', tag: 'LocalAPI', error: e);
      });

      return Message.simple(
        id: messageId,
        channelId: targetChannelId,
        senderId: senderId,
        senderName: 'Me',
        content: content,
        timestamp: now,
        type: MessageType.text,
      );
    } catch (e) {
      LoggerService().error('Failed to send message', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 获取消息列表
  Future<List<Message>> getMessages({String? channelId}) async {
    if (channelId == null) {
      throw ArgumentError('channelId 不能为空');
    }
    return getChannelMessages(channelId);
  }

  /// 获取 Channel 消息
  Future<List<Message>> getChannelMessages(String channelId, {int limit = 100}) async {
    try {
      final messages = await _db.getChannelMessages(channelId, limit: limit);
      
      List<Message> result = [];
      for (final msg in messages.reversed) {
        // 获取发送者名称
        String senderName = 'Unknown';
        if (msg['sender_type'] == 'user') {
          senderName = 'Me';
        } else if (msg['sender_type'] == 'agent') {
          final agent = await _db.getAgentById(msg['sender_id'] as String);
          senderName = agent?.name ?? 'Agent';
        }

        result.add(Message.simple(
          id: msg['id'] as String,
          channelId: msg['channel_id'] as String,
          senderId: msg['sender_id'] as String,
          senderName: senderName,
          content: msg['content'] as String,
          timestamp: DateTime.parse(msg['created_at'] as String),
          type: _parseMessageType(msg['message_type'] as String),
        ));
      }
      
      return result;
    } catch (e) {
      LoggerService().error('Failed to get message list', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  MessageType _parseMessageType(String type) {
    switch (type) {
      case 'text':
        return MessageType.text;
      case 'image':
        return MessageType.image;
      case 'file':
        return MessageType.file;
      default:
        return MessageType.text;
    }
  }

  /// 获取未读消息数
  Future<int> _getUnreadCount(String channelId) async {
    // 简化版：返回 0，实际可以基于 is_read 字段统计
    return 0;
  }

  // ==================== Agent 对话请求管理 ====================

  /// 获取待处理的对话请求
  Future<List<AgentConversationRequest>> getPendingConversationRequests() async {
    // 本地化版本：返回空列表（或可以实现完整功能）
    return [];
  }

  /// 获取用户待处理的对话请求
  Future<List<AgentConversationRequest>> getPendingApprovals(String userId) async {
    // 本地化版本：返回空列表
    return [];
  }

  /// 批准对话请求
  Future<void> approveConversationRequest(String requestId) async {
    // 本地化版本：可以实现
    LoggerService().info('Approve conversation request: $requestId', tag: 'LocalAPI');
  }

  /// 批准对话（带userId参数）
  Future<void> approveConversation(String userId, String requestId) async {
    await approveConversationRequest(requestId);
  }

  /// 拒绝对话请求
  Future<void> rejectConversationRequest(String requestId, String reason) async {
    // 本地化版本：可以实现
    LoggerService().info('Reject conversation request: $requestId, reason: $reason', tag: 'LocalAPI');
  }

  /// 拒绝对话（带userId参数）
  Future<void> rejectConversation(String userId, String requestId, {String? reason}) async {
    await rejectConversationRequest(requestId, reason ?? '');
  }

  // ==================== 初始化示例数据 ====================

  /// 初始化示例数据（首次启动时）
  Future<void> initializeSampleData() async {
    try {
      // 检查是否已有数据
      final existingAgents = await getAgents();
      if (existingAgents.isNotEmpty) {
        LoggerService().debug('Database already has data, skipping initialization', tag: 'LocalAPI');
        return;
      }

      LoggerService().debug('Skipping sample data initialization - please add agents manually', tag: 'LocalAPI');
      // 不再创建示例 Agent，用户需要手动添加真实的远端 Agent
    } catch (e) {
      LoggerService().error('Failed to initialize sample data', tag: 'LocalAPI', error: e);
    }
  }

  // ==================== 数据统计 ====================

  /// 获取数据统计信息
  Future<Map<String, dynamic>> getStats() async {
    try {
      final agents = await getAgents();
      final channels = await getChannels();
      final storageStats = await _storage.getStorageStats();

      return {
        'agentCount': agents.length,
        'channelCount': channels.length,
        'storageSize': storageStats.readableSize,
        'fileCount': storageStats.fileCount,
      };
    } catch (e) {
      LoggerService().error('Failed to get stats', tag: 'LocalAPI', error: e);
      return {};
    }
  }

  /// 注册一个 Agent
  Future<Agent> registerAgent(Agent agent) async {
    return createAgent(agent);
  }

  // ==================== Agent 响应触发 ====================

  /// 触发 Agent 响应
  /// 注意：远端 Agent 的消息路由已迁移至 ProtocolRouter，
  /// 通过 ChatScreen 直接调用 ConnectionManager 实现。
  /// 此方法仅保留用于本地 Agent 的兼容。
  Future<void> _triggerAgentResponse(String channelId, String userMessage) async {
    try {
      // 远端 Agent 响应通过 ChatScreen -> ConnectionManager -> ProtocolRouter 处理
      // 此处不再直接触发，避免重复调用
    } catch (e) {
      // 不抛出异常，避免影响消息发送
    }
  }

  /// 流式发送消息（支持 Agent 流式响应）
  Stream<Message> sendMessageStream({
    required String from,
    required String channelId,
    required String content,
    String? to,
  }) async* {
    try {
      // 1. 创建并保存用户消息
      final userMessageId = _uuid.v4();
      await _db.createMessage(
        id: userMessageId,
        channelId: channelId,
        senderId: from,
        senderType: 'user',
        senderName: 'User',
        content: content,
      );

      // 2. 创建并返回用户消息对象
      final userMessage = Message(
        id: userMessageId,
        from: MessageFrom(
          id: from,
          type: 'user',
          name: 'User',
        ),
        channelId: channelId,
        type: MessageType.text,
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      yield userMessage;

      // 远端 Agent 流式响应通过 ChatScreen -> ConnectionManager -> ProtocolRouter 处理
      // 此方法仅发送用户消息并返回

    } catch (e) {
      LoggerService().error('Failed to send streaming message', tag: 'LocalAPI', error: e);
      rethrow;
    }
  }

  /// 释放资源
  void dispose() {
    // 清理资源
  }
}
