import 'package:flutter/foundation.dart';
import '../services/logger_service.dart';
import '../models/user.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/agent_conversation_request.dart';
import '../services/local_api_service.dart';
import '../services/websocket_service.dart';

class AppState extends ChangeNotifier {
  final LocalApiService _apiService;
  final WebSocketService _wsService;

  // 当前用户
  User? _currentUser;
  User? get currentUser => _currentUser;

  // Agents
  List<Agent> _agents = [];
  List<Agent> get agents => _agents;
  List<Agent> get onlineAgents => _agents.where((a) => a.status.isOnline).toList();

  // 频道
  List<Channel> _channels = [];
  List<Channel> get channels => _channels;

  // 消息 (按频道分组)
  Map<String, List<Message>> _messagesByChannel = {};
  
  // 当前选中的频道
  Channel? _currentChannel;
  Channel? get currentChannel => _currentChannel;

  // 加载状态
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  AppState({
    LocalApiService? apiService,
    WebSocketService? wsService,
  })  : _apiService = apiService ?? LocalApiService(),
        _wsService = wsService ?? WebSocketService() {
    _initWebSocket();
  }

  /// 初始化 WebSocket
  void _initWebSocket() {
    // 监听新消息
    _wsService.messageStream.listen((message) {
      _addMessage(message);
      notifyListeners();
    });

    // 监听新频道
    _wsService.channelStream.listen((channel) {
      _channels.add(channel);
      notifyListeners();
    });

    // 监听新 Agent
    _wsService.agentStream.listen((agent) {
      final index = _agents.indexWhere((a) => a.id == agent.id);
      if (index >= 0) {
        _agents[index] = agent;
      } else {
        _agents.add(agent);
      }
      notifyListeners();
    });
  }

  /// 用户登录
  Future<bool> login(String username, String avatar) async {
    _setLoading(true);
    _error = null;

    try {
      // HTTP 登录
      final result = await _apiService.login(username, avatar);
      
      _currentUser = result['user'] as User;
      _channels = result['channels'] as List<Channel>;
      _agents = result['agents'] as List<Agent>;

      // WebSocket 连接
      await _wsService.connect();
      _wsService.login(username, avatar);

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  /// 创建与 Agent 的私聊
  Future<Channel?> createDMWithAgent(String agentId) async {
    if (_currentUser == null) return null;

    _setLoading(true);
    try {
      final channel = await _apiService.createDM(_currentUser!.id, agentId);
      
      // 检查是否已存在
      if (!_channels.any((c) => c.id == channel.id)) {
        _channels.add(channel);
      }
      
      _setLoading(false);
      notifyListeners();
      return channel;
    } catch (e) {
      _error = e.toString();
      _setLoading(false);
      notifyListeners();
      return null;
    }
  }

  /// 创建群聊
  Future<Channel?> createGroup(String name, List<String> agentIds) async {
    if (_currentUser == null) return null;

    _setLoading(true);
    try {
      final channel = await _apiService.createGroup(
        _currentUser!.id,
        name,
        agentIds,
      );
      
      _channels.add(channel);
      
      _setLoading(false);
      notifyListeners();
      return channel;
    } catch (e) {
      _error = e.toString();
      _setLoading(false);
      notifyListeners();
      return null;
    }
  }

  /// 发送消息
  Future<bool> sendMessage(String content, {String? channelId, String? toAgentId}) async {
    if (_currentUser == null) return false;

    try {
      final message = await _apiService.sendMessage(
        from: _currentUser!.id,
        to: toAgentId,
        channelId: channelId,
        content: content,
      );

      _addMessage(message);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 流式发送消息（支持 Agent 流式响应）
  Stream<Message> sendMessageStream(String content, {required String channelId}) async* {
    if (_currentUser == null) return;

    try {
      await for (final message in _apiService.sendMessageStream(
        from: _currentUser!.id,
        channelId: channelId,
        content: content,
      )) {
        // 更新消息到缓存
        _addOrUpdateMessage(message);
        notifyListeners();
        yield message;
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// 添加或更新消息到缓存
  void _addOrUpdateMessage(Message message) {
    final channelId = message.channelId ?? '';

    if (channelId.isEmpty) {
      LoggerService().warning('Message has no channelId', tag: 'AppState');
      return;
    }

    if (!_messagesByChannel.containsKey(channelId)) {
      _messagesByChannel[channelId] = [];
    }

    // 查找是否已存在相同 ID 的消息
    final existingIndex = _messagesByChannel[channelId]!
        .indexWhere((m) => m.id == message.id);

    if (existingIndex != -1) {
      // 更新现有消息
      _messagesByChannel[channelId]![existingIndex] = message;
    } else {
      // 添加新消息
      _messagesByChannel[channelId]!.add(message);
    }
  }

  /// 加载频道消息
  Future<void> loadChannelMessages(String channelId) async {
    try {
      final messages = await _apiService.getMessages(channelId: channelId);
      _messagesByChannel[channelId] = messages;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 选择频道
  void selectChannel(Channel channel) {
    _currentChannel = channel;
    
    // 如果消息未加载,加载消息
    if (!_messagesByChannel.containsKey(channel.id)) {
      loadChannelMessages(channel.id);
    }
    
    notifyListeners();
  }

  /// 获取频道消息
  List<Message> getChannelMessages(String channelId) {
    return _messagesByChannel[channelId] ?? [];
  }

  /// 获取当前频道消息
  List<Message> get currentChannelMessages {
    if (_currentChannel == null) return [];
    return getChannelMessages(_currentChannel!.id);
  }

  /// 刷新 Agents
  Future<void> refreshAgents() async {
    try {
      _agents = await _apiService.getAgents();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 刷新频道列表
  Future<void> refreshChannels() async {
    if (_currentUser == null) return;

    try {
      _channels = await _apiService.getUserChannels(_currentUser!.id);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ============================================
  // Agent 对话确认相关
  // ============================================

  /// 获取待确认的 Agent 对话请求
  Future<List<AgentConversationRequest>> getPendingApprovals() async {
    if (_currentUser == null) return [];

    try {
      return await _apiService.getPendingApprovals(_currentUser!.id);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  /// 批准 Agent 对话
  Future<void> approveConversation(String requestId) async {
    if (_currentUser == null) return;

    try {
      await _apiService.approveConversation(_currentUser!.id, requestId);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// 拒绝 Agent 对话
  Future<void> rejectConversation(String requestId, {String? reason}) async {
    if (_currentUser == null) return;

    try {
      await _apiService.rejectConversation(
        _currentUser!.id,
        requestId,
        reason: reason,
      );
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// 添加消息到缓存
  void _addMessage(Message message) {
    final channelId = message.channelId ?? '';

    if (channelId.isEmpty) {
      LoggerService().warning('Message has no channelId', tag: 'AppState');
      return;
    }

    if (!_messagesByChannel.containsKey(channelId)) {
      _messagesByChannel[channelId] = [];
    }

    // 避免重复
    if (!_messagesByChannel[channelId]!.any((m) => m.id == message.id)) {
      _messagesByChannel[channelId]!.add(message);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _apiService.dispose();
    _wsService.dispose();
    super.dispose();
  }
}
