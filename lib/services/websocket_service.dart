import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/message.dart';
import '../models/channel.dart';
import '../models/agent.dart';
import '../config/app_config.dart';
import '../services/logger_service.dart';
import '../utils/exceptions.dart';

class WebSocketService {
  final String wsUrl;
  WebSocketChannel? _channel;
  final _messageController = StreamController<Message>.broadcast();
  final _channelController = StreamController<Channel>.broadcast();
  final _agentController = StreamController<Agent>.broadcast();

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Channel> get channelStream => _channelController.stream;
  Stream<Agent> get agentStream => _agentController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;

  WebSocketService({String? wsUrl}) 
      : wsUrl = wsUrl ?? AppConfig.current.wsBaseUrl;

  /// 连接 WebSocket
  Future<void> connect() async {
    if (_isConnected) return;
    
    _manualDisconnect = false;

    try {
      LoggerService().info('Connecting WebSocket: $wsUrl', tag: 'WebSocket');
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _isConnected = true;
      _reconnectAttempts = 0;

      _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          LoggerService().error('WebSocket error', tag: 'WebSocket', error: error);
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          LoggerService().warning('WebSocket connection closed', tag: 'WebSocket');
          _isConnected = false;
          _scheduleReconnect();
        },
      );

      LoggerService().info('WebSocket connected', tag: 'WebSocket');
    } catch (e) {
      LoggerService().error('WebSocket connection failed', tag: 'WebSocket', error: e);
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  /// 安排重连（指数退避）
  void _scheduleReconnect() {
    if (_manualDisconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      if (_reconnectAttempts >= _maxReconnectAttempts) {
        LoggerService().error('WebSocket reconnect failed, max retries reached', tag: 'WebSocket');
      }
      return;
    }

    _reconnectAttempts++;
    final delay = Duration(seconds: (2 * _reconnectAttempts).clamp(1, 30));
    
    LoggerService().info('Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)', tag: 'WebSocket');
    
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_isConnected && !_manualDisconnect) {
        connect();
      }
    });
  }

  /// 处理收到的消息
  void _handleMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String);
      final type = json['type'];

      switch (type) {
        case 'message':
          final message = Message.fromJson(json['data']);
          _messageController.add(message);
          LoggerService().debug('Received message: ${message.id}', tag: 'WebSocket');
          break;

        case 'channel_created':
          final channel = Channel.fromJson(json['data']);
          _channelController.add(channel);
          LoggerService().debug('Channel created: ${channel.id}', tag: 'WebSocket');
          break;

        case 'agent_registered':
          final agent = Agent.fromJson(json['data']);
          _agentController.add(agent);
          LoggerService().debug('Agent registered: ${agent.id}', tag: 'WebSocket');
          break;

        case 'login_success':
          LoggerService().info('WebSocket login success', tag: 'WebSocket');
          break;

        default:
          LoggerService().warning('Unknown WebSocket message type: $type', tag: 'WebSocket');
      }
    } catch (e, stackTrace) {
      LoggerService().error('Failed to parse WebSocket message', tag: 'WebSocket', error: e, stackTrace: stackTrace);
    }
  }

  /// 发送登录消息
  void login(String username, String avatar) {
    if (!_isConnected) {
      LoggerService().warning('WebSocket not connected, cannot send login', tag: 'WebSocket');
      return;
    }

    final message = jsonEncode({
      'type': 'login',
      'username': username,
      'avatar': avatar,
    });

    _channel?.sink.add(message);
    LoggerService().debug('Sending login: $username', tag: 'WebSocket');
  }

  /// 断开连接
  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _isConnected = false;
    LoggerService().info('WebSocket manually disconnected', tag: 'WebSocket');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _channelController.close();
    _agentController.close();
  }
}
