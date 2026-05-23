/// Channel Tunnel 服务
/// 实现 tunnel-http / tunnel-ws 协议，将外网请求通过 Channel 服务隧道转发到本地 ACP Server
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'logger_service.dart';
import '../peer/services/peer_channel_bridge.dart';

// ACP Server 默认端口（与 main.dart 保持一致）
const _kAcpDefaultPort = 18790;
const _kAcpPortPrefKey = 'acp_server_port';

// ── 配置模型 ─────────────────────────────────────────────────────────────────

/// Channel Tunnel 配置
class ChannelTunnelConfig {
  final String serverUrl;       // https://channel.xxx.com
  final String channelId;       // channel ID
  final String secret;          // ch_sec_xxx
  final String? channelEndpoint; // channel endpoint 字段（用于拼接外网访问地址）
  final bool autoConnect;       // 是否自动连接

  const ChannelTunnelConfig({
    required this.serverUrl,
    required this.channelId,
    required this.secret,
    this.channelEndpoint,
    this.autoConnect = false,
  });

  ChannelTunnelConfig copyWith({
    String? serverUrl,
    String? channelId,
    String? secret,
    String? channelEndpoint,
    bool? autoConnect,
  }) {
    return ChannelTunnelConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      channelId: channelId ?? this.channelId,
      secret: secret ?? this.secret,
      channelEndpoint: channelEndpoint ?? this.channelEndpoint,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'channelId': channelId,
        'secret': secret,
        if (channelEndpoint != null) 'channelEndpoint': channelEndpoint,
        'autoConnect': autoConnect,
      };

  factory ChannelTunnelConfig.fromJson(Map<String, dynamic> json) =>
      ChannelTunnelConfig(
        serverUrl: json['serverUrl'] as String,
        channelId: json['channelId'] as String,
        secret: json['secret'] as String,
        channelEndpoint: json['channelEndpoint'] as String?,
        autoConnect: json['autoConnect'] as bool? ?? false,
      );
}

// ── 状态枚举 ─────────────────────────────────────────────────────────────────

enum TunnelStatus {
  idle,         // 未启动
  connecting,   // 正在连接
  connected,    // 已连接
  disconnected, // 已断开（正在重连）
  error,        // 错误
}

// ── Tunnel 消息 ───────────────────────────────────────────────────────────────

class _TunnelMessage {
  final String type;
  final int streamId;
  final String method;
  final String path;
  final Map<String, String> headers;
  final int status;
  final String body; // base64
  final String error;
  final int wsMsgType; // 1=text, 2=binary (only for ws_data)

  const _TunnelMessage({
    required this.type,
    this.streamId = 0,
    this.method = '',
    this.path = '',
    this.headers = const {},
    this.status = 0,
    this.body = '',
    this.error = '',
    this.wsMsgType = 0,
  });

  factory _TunnelMessage.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    final Map<String, String> headers = {};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        headers[k.toString()] = v.toString();
      });
    }
    return _TunnelMessage(
      type: json['type'] as String? ?? '',
      streamId: (json['stream_id'] as num?)?.toInt() ?? 0,
      method: json['method'] as String? ?? '',
      path: json['path'] as String? ?? '',
      headers: headers,
      status: (json['status'] as num?)?.toInt() ?? 0,
      body: json['body'] as String? ?? '',
      error: json['error'] as String? ?? '',
      wsMsgType: (json['ws_msg_type'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'type': type};
    if (streamId != 0) map['stream_id'] = streamId;
    if (method.isNotEmpty) map['method'] = method;
    if (path.isNotEmpty) map['path'] = path;
    if (headers.isNotEmpty) map['headers'] = headers;
    if (status != 0) map['status'] = status;
    if (body.isNotEmpty) map['body'] = body;
    if (error.isNotEmpty) map['error'] = error;
    if (wsMsgType != 0) map['ws_msg_type'] = wsMsgType;
    return map;
  }
}

// ── Channel Tunnel Service ────────────────────────────────────────────────────

/// Channel Tunnel 服务（单例）
/// 负责建立和维护到 Channel 服务的 WebSocket 隧道连接
class ChannelTunnelService {
  ChannelTunnelService._();
  static final ChannelTunnelService instance = ChannelTunnelService._();

  static const _tag = 'ChannelTunnel';
  static const _prefKey = 'channel_tunnel_config';

  final _log = LoggerService();
  final _statusController = StreamController<TunnelStatus>.broadcast();

  TunnelStatus _status = TunnelStatus.idle;
  bool _running = false;      // 用户主动启动
  bool _stopRequested = false; // 用户主动停止

  WebSocketChannel? _channel;
  ChannelTunnelConfig? _config;

  /// Per-stream channels for WebSocket proxy (stream_id -> sink of incoming ws_data/ws_close msgs)
  final Map<int, StreamController<_TunnelMessage>> _wsStreams = {};

  // ── 动态读取 ACP Server 端口 ──────────────────────────────────────────────

  /// 从 SharedPreferences 读取用户配置的 ACP Server 端口，默认 18790
  Future<String> _getAcpTarget() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(_kAcpPortPrefKey) ?? _kAcpDefaultPort;
    return 'http://127.0.0.1:$port';
  }

  // ── 公开接口 ──────────────────────────────────────────────────────────────

  TunnelStatus get currentStatus => _status;
  bool get isRunning => _running;
  Stream<TunnelStatus> get statusStream => _statusController.stream;

  /// 加载持久化配置
  Future<ChannelTunnelConfig?> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefKey);
      if (json == null) return null;
      return ChannelTunnelConfig.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
    } catch (e) {
      _log.error('Failed to load tunnel config', tag: _tag, error: e);
      return null;
    }
  }

  /// 保存配置
  Future<void> saveConfig(ChannelTunnelConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(config.toJson()));
      _config = config;
    } catch (e) {
      _log.error('Failed to save tunnel config', tag: _tag, error: e);
    }
  }

  /// 清除配置
  Future<void> clearConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
      _config = null;
    } catch (e) {
      _log.error('Failed to clear tunnel config', tag: _tag, error: e);
    }
  }

  /// 启动 Tunnel（从配置文件加载配置，或使用已保存的 _config）
  Future<void> start() async {
    if (_running) return;

    final config = _config ?? await loadConfig();
    if (config == null) {
      _log.warning('No tunnel config found, cannot start', tag: _tag);
      return;
    }
    await startWithConfig(config);
  }

  /// 用指定配置启动 Tunnel（不依赖 SharedPreferences，适用于 per-agent 配置）
  Future<void> startWithConfig(ChannelTunnelConfig config) async {
    if (_running) return;

    _config = config;
    _running = true;
    _stopRequested = false;
    _setStatus(TunnelStatus.connecting);

    // 在后台运行重连循环
    _runLoop();
  }

  /// 停止 Tunnel
  Future<void> stop() async {
    _stopRequested = true;
    _running = false;
    await _disconnect();
    _setStatus(TunnelStatus.idle);
  }

  /// 获取外网访问地址（基于 channelEndpoint 或 channelId 拼接）
  String? getPublicEndpoint(ChannelTunnelConfig config) {
    final base = config.serverUrl.replaceFirst(RegExp(r'^http://'), 'ws://')
        .replaceFirst(RegExp(r'^https://'), 'wss://');
    final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;

    if (config.channelEndpoint != null && config.channelEndpoint!.isNotEmpty) {
      return '$trimmed/c/${config.channelEndpoint}/acp/ws';
    }
    return '$trimmed/proxy/${config.channelId}/acp/ws';
  }

  // ── 内部实现 ──────────────────────────────────────────────────────────────

  void _setStatus(TunnelStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Future<void> _runLoop() async {
    var backoff = const Duration(seconds: 2);
    const maxBackoff = Duration(seconds: 60);

    while (_running && !_stopRequested) {
      try {
        _setStatus(TunnelStatus.connecting);
        await _connect();
        // 连接成功
        _setStatus(TunnelStatus.connected);
        backoff = const Duration(seconds: 2); // 重置退避

        _log.info('Tunnel connected to ${_config!.serverUrl}', tag: _tag);

        // 阻塞直到连接断开
        await _listen();
      } catch (e) {
        if (_stopRequested) break;
        _log.warning('Tunnel connection error: $e', tag: _tag);
        _setStatus(TunnelStatus.disconnected);
      }

      if (_stopRequested || !_running) break;

      _log.info('Reconnecting in ${backoff.inSeconds}s...', tag: _tag);
      _setStatus(TunnelStatus.disconnected);
      await Future.delayed(backoff);
      backoff = backoff * 2;
      if (backoff > maxBackoff) backoff = maxBackoff;
    }
  }

  Future<void> _connect() async {
    final config = _config!;
    final base = config.serverUrl
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://');
    final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;

    // HMAC-SHA256 签名认证（密钥不上线）
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final nonce = _generateNonce();
    final signingString = '${config.channelId}\n$timestamp\n$nonce';
    final hmacSha256 = Hmac(sha256, utf8.encode(config.secret));
    final signature = hmacSha256.convert(utf8.encode(signingString)).toString();

    final wsUrl =
        '$trimmed/tunnel/connect?channel_id=${Uri.encodeComponent(config.channelId)}'
        '&timestamp=${Uri.encodeComponent(timestamp)}'
        '&nonce=${Uri.encodeComponent(nonce)}'
        '&signature=${Uri.encodeComponent(signature)}';
    final uri = Uri.parse(wsUrl);

    _log.debug('Tunnel connecting to $trimmed/tunnel/connect', tag: _tag);

    // 使用 dart:io WebSocket.connect 直接连接，行为更可预期（握手失败立即抛出异常）
    // web_socket_channel.connect 在某些情况下 ready 不会及时抛出错误
    final ioSocket = await io.WebSocket.connect(uri.toString());
    _channel = IOWebSocketChannel(ioSocket);

    _log.debug('Tunnel WebSocket handshake complete, channel_id=${config.channelId}', tag: _tag);
  }

  /// 生成随机 nonce（16字节 hex，32字符）
  static String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _listen() async {
    final channel = _channel;
    if (channel == null) return;

    final completer = Completer<void>();

    final sub = channel.stream.listen(
      (data) {
        if (data is String) {
          _handleMessage(data);
        }
      },
      onError: (e) {
        _log.warning('Tunnel stream error: $e', tag: _tag);
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        _log.info('Tunnel stream closed (remote closed connection)', tag: _tag);
        if (!completer.isCompleted) completer.complete();
      },
    );

    try {
      await completer.future;
    } finally {
      await sub.cancel();
      // 清空引用，避免重连时误用旧 channel
      _channel = null;
    }
  }

  Future<void> _disconnect() async {
    // 向所有活跃的 WS proxy streams 发送关闭信号，让代理协程优雅退出
    // 注意：不直接 close() controller，而是先加入 ws_close 消息再 close，
    // 这样即使 _forwardWsConnect 的 tunnelSub.onDone 触发，
    // 它能知道是隧道断开导致的，而不是误把 localWs 关掉。
    for (final entry in _wsStreams.entries) {
      final ctrl = entry.value;
      if (!ctrl.isClosed) {
        try {
          ctrl.add(const _TunnelMessage(type: 'ws_close'));
          ctrl.close();
        } catch (_) {}
      }
    }
    _wsStreams.clear();

    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _handleMessage(String rawData) {
    try {
      final json = jsonDecode(rawData) as Map<String, dynamic>;
      final msg = _TunnelMessage.fromJson(json);

      switch (msg.type) {
        case 'ping':
          _sendMessage(const _TunnelMessage(type: 'pong'));

        case 'request':
          // 并发处理每个请求
          _handleRequest(msg);

        case 'ws_connect':
          // 建立到本地 ACP Server 的 WebSocket 连接，双向转发帧
          _handleWsConnect(msg);

        case 'ws_data':
        case 'ws_close':
          // 路由到对应 stream 的处理器
          final ctrl = _wsStreams[msg.streamId];
          if (ctrl != null && !ctrl.isClosed) {
            ctrl.add(msg);
          }

        case 'close':
          _log.info('Server closed tunnel (secret may have been rotated)', tag: _tag);
          _channel?.sink.close();

        default:
          _log.debug('Unknown tunnel message type: ${msg.type}', tag: _tag);
      }
    } catch (e) {
      _log.error('Failed to parse tunnel message', tag: _tag, error: e);
    }
  }

  /// 建立到本地 ACP Server 的 WebSocket 连接，双向转发帧
  void _handleWsConnect(_TunnelMessage req) {
    // 异步处理，不阻塞消息循环
    _forwardWsConnect(req).catchError((e) {
      _log.error('WS proxy error stream=${req.streamId}', tag: _tag, error: e);
    });
  }

  Future<void> _forwardWsConnect(_TunnelMessage req) async {
    // strip /proxy/{channelId} 前缀，得到真实路径（如 /acp/ws?agentId=xxx）
    // 也支持 /c/{channelEndpoint} 前缀（short-url 模式）
    final channelId = _config!.channelId;
    final channelEndpoint = _config!.channelEndpoint;
    String strippedPath = req.path;
    final proxyPrefix = '/proxy/$channelId';
    if (strippedPath.startsWith(proxyPrefix)) {
      strippedPath = strippedPath.substring(proxyPrefix.length);
    } else if (channelEndpoint != null && channelEndpoint.isNotEmpty) {
      final shortPrefix = '/c/$channelEndpoint';
      if (strippedPath.startsWith(shortPrefix)) {
        strippedPath = strippedPath.substring(shortPrefix.length);
      }
    }

    // P2P 连接路由：/peer/ws 路径交给 PeerChannelBridge 处理
    if (strippedPath.startsWith('/peer/ws')) {
      _log.info('ws_connect routed to P2P handler, stream=${req.streamId}', tag: _tag);
      _handlePeerWsConnect(req.streamId);
      return;
    }

    // 构建目标 WS URL（本地 ACP Server，端口从 SharedPreferences 读取）
    final acpTarget = await _getAcpTarget();
    final targetUri = Uri.parse(
      acpTarget.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://') + strippedPath,
    );

    _log.info(
      'ws_connect stream=${req.streamId} path="${req.path}" → stripped="$strippedPath" → target=$targetUri',
      tag: _tag,
    );
    _log.debug(
      'ws_connect headers: ${req.headers.keys.join(', ')}',
      tag: _tag,
    );

    // 注册 per-stream controller，用于接收来自 server 端的 ws_data/ws_close
    // 使用带缓冲的普通 StreamController（非 broadcast），确保在 await connect() 期间
    // 到达的消息不会丢失（broadcast controller 在无订阅者时直接丢弃事件）
    final streamCtrl = StreamController<_TunnelMessage>();
    _wsStreams[req.streamId] = streamCtrl;

    WebSocketChannel? localWs;
    try {
      // 连接本地 ACP Server，转发 headers（含 Authorization）
      final ioSocket = await io.WebSocket.connect(
        targetUri.toString(),
        headers: Map<String, dynamic>.from(req.headers),
      );
      localWs = IOWebSocketChannel(ioSocket);
      await localWs.ready;
    } catch (e) {
      _log.warning('WS dial local failed ($targetUri): $e', tag: _tag);
      _sendMessage(_TunnelMessage(type: 'ws_close', streamId: req.streamId));
      streamCtrl.close();
      _wsStreams.remove(req.streamId);
      return;
    }

    _log.debug('WS proxy connected stream=${req.streamId} -> $targetUri', tag: _tag);

    // Completer 用于等待任意一侧关闭
    final done = Completer<void>();

    // local → tunnel 方向
    final localSub = localWs.stream.listen(
      (data) {
        // dart:io WebSocket delivers String (text) or Uint8List (binary)
        final isText = data is String;
        final bytes = isText ? utf8.encode(data as String) : Uint8List.fromList(data as List<int>);
        _sendMessage(_TunnelMessage(
          type: 'ws_data',
          streamId: req.streamId,
          body: base64Encode(bytes),
          wsMsgType: isText ? 1 : 2, // 1=TextMessage, 2=BinaryMessage
        ));
      },
      onError: (_) {
        _sendMessage(_TunnelMessage(type: 'ws_close', streamId: req.streamId));
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        _sendMessage(_TunnelMessage(type: 'ws_close', streamId: req.streamId));
        if (!done.isCompleted) done.complete();
      },
    );

    // tunnel → local 方向
    // 注意：streamCtrl 是普通（非 broadcast）controller，
    // 消息在 await connect() 期间已缓存在队列里，listen 后会立即分发
    final tunnelSub = streamCtrl.stream.listen(
      (msg) {
        if (msg.type == 'ws_close') {
          localWs?.sink.close();
          if (!done.isCompleted) done.complete();
          return;
        }
        if (msg.type == 'ws_data') {
          final bytes = base64Decode(msg.body);
          if (msg.wsMsgType == 1) {
            localWs?.sink.add(utf8.decode(bytes)); // text frame
          } else {
            localWs?.sink.add(bytes); // binary frame
          }
        }
      },
      onDone: () {
        // streamCtrl 被 _disconnect() 关闭时触发
        // 此时隧道已断开，关闭本地 ACP Server 连接
        localWs?.sink.close();
        if (!done.isCompleted) done.complete();
      },
    );

    // 等待任意一侧关闭后统一清理
    await done.future;
    await tunnelSub.cancel();
    await localSub.cancel();
    // 清理前先从 map 里移除，防止 _disconnect() 重复关闭
    _wsStreams.remove(req.streamId);
    if (!streamCtrl.isClosed) {
      await streamCtrl.close();
    }
    _log.debug('WS proxy closed stream=${req.streamId}', tag: _tag);
  }

  void _handleRequest(_TunnelMessage req) {
    // 异步处理，不阻塞消息循环
    _forwardRequest(req).catchError((e) {
      _log.error('Request forwarding error', tag: _tag, error: e);
    });
  }

  Future<void> _forwardRequest(_TunnelMessage req) async {
    try {
      // 解码请求体
      final bodyBytes = req.body.isNotEmpty
          ? base64Decode(req.body)
          : null;

      final targetUrl = (await _getAcpTarget()) + req.path;
      final httpReq = io.HttpClient();
      httpReq.connectionTimeout = const Duration(seconds: 25);

      final uri = Uri.parse(targetUrl);
      final request = await httpReq.openUrl(req.method.toUpperCase(), uri);

      // 转发 headers（跳过 host）
      req.headers.forEach((k, v) {
        if (k.toLowerCase() != 'host') {
          request.headers.set(k, v);
        }
      });

      if (bodyBytes != null && bodyBytes.isNotEmpty) {
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }

      final response = await request.close();

      // 读取响应体（最多 32MB）
      final respBodyBytes = await _readResponseBody(response);
      final respBodyB64 = base64Encode(respBodyBytes);

      // 收集响应 headers
      final respHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) {
          respHeaders[name] = values.first;
        }
      });

      httpReq.close();

      _sendMessage(_TunnelMessage(
        type: 'response',
        streamId: req.streamId,
        status: response.statusCode,
        headers: respHeaders,
        body: respBodyB64,
      ));
    } catch (e) {
      _sendMessage(_TunnelMessage(
        type: 'response',
        streamId: req.streamId,
        status: 502,
        error: 'local request error: $e',
      ));
    }
  }

  Future<List<int>> _readResponseBody(io.HttpClientResponse response) async {
    const maxBytes = 32 * 1024 * 1024; // 32MB
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
    return bytes;
  }

  void _sendMessage(_TunnelMessage msg) {
    try {
      _channel?.sink.add(jsonEncode(msg.toJson()));
    } catch (e) {
      _log.error('Failed to send tunnel message', tag: _tag, error: e);
    }
  }

  // ── P2P Peer 连接处理 ──────────────────────────────────────────────────

  /// 跟踪哪些 streamId 属于 peer 连接
  final Set<int> _peerStreamIds = {};

  /// 处理 /peer/ws 的 ws_connect 请求
  void _handlePeerWsConnect(int streamId) {
    _peerStreamIds.add(streamId);

    // 注册到 _wsStreams，复用现有的消息路由机制
    final streamCtrl = StreamController<_TunnelMessage>();
    _wsStreams[streamId] = streamCtrl;

    // 绑定 tunnel sender（如果尚未绑定）
    final bridge = PeerChannelBridge.instance;
    bridge.bindTunnelSender((msg) => _sendMessage(_TunnelMessage(
      type: msg['type'] as String,
      streamId: (msg['stream_id'] as num?)?.toInt() ?? 0,
      body: msg['body'] as String? ?? '',
      wsMsgType: (msg['ws_msg_type'] as num?)?.toInt() ?? 0,
    )));

    // 通知 bridge 有新的 peer 连接
    bridge.handlePeerWsConnect(streamId);

    // 监听隧道消息并转发给 bridge
    streamCtrl.stream.listen(
      (msg) {
        if (msg.type == 'ws_close') {
          bridge.handlePeerWsClose(streamId);
          _peerStreamIds.remove(streamId);
          _wsStreams.remove(streamId);
          if (!streamCtrl.isClosed) streamCtrl.close();
        } else if (msg.type == 'ws_data') {
          final bytes = base64Decode(msg.body);
          bridge.handlePeerWsData(streamId, Uint8List.fromList(bytes));
        }
      },
      onDone: () {
        bridge.handlePeerWsClose(streamId);
        _peerStreamIds.remove(streamId);
      },
    );
  }

  void dispose() {
    _stopRequested = true;
    _running = false;
    _peerStreamIds.clear();
    PeerChannelBridge.instance.unbindTunnelSender();
    _channel?.sink.close();
    _statusController.close();
  }
}
