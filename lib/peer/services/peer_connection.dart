/// 单个 P2P 连接的状态机
///
/// 封装了 WebSocket 传输层 + Noise 加密会话，
/// 提供加密的消息收发能力。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:io' as io;

import '../../services/noise_identity.dart';
import '../../services/noise/noise_session.dart';
import '../../services/noise/noise_envelope.dart';
import '../../services/logger_service.dart';
import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import 'peer_channel_bridge.dart';

/// 连接事件类型
enum PeerConnectionEventType {
  connected,
  disconnected,
  messageReceived,
  error,
}

/// 连接事件
class PeerConnectionEvent {
  final String peerId;
  final PeerConnectionEventType type;
  final dynamic data; // PeerMessage for messageReceived, String for error

  PeerConnectionEvent({
    required this.peerId,
    required this.type,
    this.data,
  });
}

/// 单个 P2P 加密连接
class PeerConnection {
  final PairedPeer peer;
  final _log = LoggerService();
  static const _tag = 'PeerConn';

  NoiseSession? _noiseSession;
  WebSocketChannel? _wsChannel;
  PeerTunnelStream? _tunnelStream;
  StreamSubscription? _incomingSub;
  Timer? _heartbeatTimer;
  DateTime? _lastActivity;
  bool _closed = false;

  /// 发送队列锁 — 保证 encrypt + send 的原子性（防止 nonce 乱序）
  Future<void> _sendLock = Future.value();

  /// 接收队列锁 — 保证 decrypt 的顺序性
  Future<void> _recvLock = Future.value();

  /// 连接状态
  PeerConnectionState _state = PeerConnectionState.disconnected;
  PeerConnectionState get state => _state;

  /// 收到的解密消息
  final _messageController = StreamController<PeerMessage>.broadcast();
  Stream<PeerMessage> get messages => _messageController.stream;

  /// 收到的回执事件
  final _ackController = StreamController<PeerAckEvent>.broadcast();
  Stream<PeerAckEvent> get acks => _ackController.stream;

  /// 连接状态变化
  final _stateController = StreamController<PeerConnectionState>.broadcast();
  Stream<PeerConnectionState> get stateChanges => _stateController.stream;

  PeerConnection({required this.peer});

  /// 从已完成握手的 session 创建（用于接受入站连接）
  PeerConnection.fromEstablishedSession({
    required this.peer,
    required NoiseSession noiseSession,
    PeerTunnelStream? tunnelStream,
    WebSocketChannel? wsChannel,
    Stream<Uint8List>? incomingStream,
  }) {
    _noiseSession = noiseSession;
    _tunnelStream = tunnelStream;
    _wsChannel = wsChannel;
    _state = PeerConnectionState.connected;
    _startHeartbeat();
    // 使用提供的 incomingStream（已被预处理过的 relay stream）
    if (incomingStream != null) {
      _incomingSub = incomingStream.listen(
        (data) => _handleIncomingFrame(utf8.decode(data)),
        onDone: () {
          _log.info('Incoming stream closed for ${peer.deviceName}', tag: _tag);
          _setState(PeerConnectionState.disconnected);
        },
      );
    } else if (tunnelStream != null) {
      _listenTunnelStream(tunnelStream);
    } else if (wsChannel != null) {
      _listenWebSocket();
    }
  }

  /// 通过直接 WebSocket 连接对方（Initiator 侧）
  /// 用于主动连接已配对设备的 Channel 端点
  Future<void> connectViaWebSocket(String endpoint) async {
    if (_closed) return;
    _setState(PeerConnectionState.connecting);

    try {
      final ioSocket = await io.WebSocket.connect(endpoint)
          .timeout(const Duration(seconds: 10));
      _wsChannel = IOWebSocketChannel(ioSocket);

      // 先建立单一 subscription，用 Completer 取 msg2，之后继续用同一个 sub
      final handshakeCompleter = Completer<String>();
      _incomingSub = _wsChannel!.stream.listen(
        (data) {
          final frame = data is String ? data : utf8.decode(data as List<int>);
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.complete(frame);
          } else {
            _handleIncomingFrame(frame);
          }
        },
        onError: (e) {
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(e);
          }
          _log.warning('WebSocket error: $e', tag: _tag);
          _setState(PeerConnectionState.disconnected);
        },
        onDone: () {
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(StateError('WebSocket closed during handshake'));
          }
          _log.info('WebSocket closed for ${peer.deviceName}', tag: _tag);
          _setState(PeerConnectionState.disconnected);
        },
      );

      // Noise IK 握手（使用 completer 等待 msg2）
      await _performInitiatorHandshake(handshakeCompleter);

      _setState(PeerConnectionState.connected);
      _startHeartbeat();
    } catch (e) {
      _log.error('Connection failed to ${peer.deviceName}', tag: _tag, error: e);
      _incomingSub?.cancel();
      _incomingSub = null;
      _setState(PeerConnectionState.disconnected);
      rethrow;
    }
  }

  /// 发送加密消息
  Future<void> sendMessage(PeerMessage message) async {
    await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'message',
      'payload': message.toWireJson(),
    }))));
    _lastActivity = DateTime.now();
  }

  /// 发送心跳
  Future<void> _sendHeartbeat() async {
    await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'ping',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }))));
  }

  /// 序列化发送 — 确保 encrypt + send 原子执行，防止 nonce 并发冲突
  Future<void> _serializedSend(Uint8List plaintext) async {
    final prev = _sendLock;
    final completer = Completer<void>();
    _sendLock = completer.future;

    await prev; // 等待上一次发送完成
    try {
      if (_noiseSession == null || !_noiseSession!.ready) return;
      final ciphertext = await _noiseSession!.encrypt(plaintext);
      final frame = encodeFrame(Frame(t: FrameType.data, payload: ciphertext));
      _send(frame);
    } catch (e) {
      _log.error('Serialized send failed', tag: _tag, error: e);
    } finally {
      completer.complete();
    }
  }

  /// 关闭连接
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _incomingSub?.cancel();
    _noiseSession?.close();
    _wsChannel?.sink.close();
    _tunnelStream?.close();
    _setState(PeerConnectionState.disconnected);
    _messageController.close();
    _ackController.close();
    _stateController.close();
  }

  // ── 内部方法 ────────────────────────────────────────────────────────────

  Future<void> _performInitiatorHandshake(Completer<String> msg2Completer) async {
    final identity = await NoiseIdentity.loadOrCreate();
    _noiseSession = await NoiseSession.initiator(
      staticPublicKey: identity.publicKey,
      staticPrivateKey: identity.privateKey,
      pinnedPeerStaticPublicKey: peer.publicKey,
    );

    // 发送 msg1
    final msg1Payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'reconnect',
      'device_id': identity.fingerprintHex,
    })));
    final msg1 = await _noiseSession!.writeHandshake1(msg1Payload);
    final frame1 = encodeFrame(Frame(t: FrameType.hs, payload: msg1));
    _send(frame1);

    // 等待 msg2（通过 Completer，复用同一个 subscription）
    final msg2Raw = await msg2Completer.future.timeout(const Duration(seconds: 15));
    final msg2Frame = decodeFrame(msg2Raw);
    if (msg2Frame.t != FrameType.hs) {
      throw StateError('Expected handshake frame, got ${msg2Frame.t}');
    }
    await _noiseSession!.readHandshake2(msg2Frame.payload);
  }

  void _listenWebSocket() {
    _incomingSub = _wsChannel!.stream.listen(
      (data) {
        final frame = data is String ? data : utf8.decode(data as List<int>);
        _handleIncomingFrame(frame);
      },
      onError: (e) {
        _log.warning('WebSocket error: $e', tag: _tag);
        _setState(PeerConnectionState.disconnected);
      },
      onDone: () {
        _log.info('WebSocket closed for ${peer.deviceName}', tag: _tag);
        _setState(PeerConnectionState.disconnected);
      },
    );
  }

  void _listenTunnelStream(PeerTunnelStream stream) {
    _incomingSub = stream.incoming.listen(
      (data) {
        final frame = utf8.decode(data);
        _handleIncomingFrame(frame);
      },
      onDone: () {
        _log.info('Tunnel stream closed for ${peer.deviceName}', tag: _tag);
        _setState(PeerConnectionState.disconnected);
      },
    );
  }

  Future<void> _handleIncomingFrame(String raw) async {
    // 序列化接收处理 — 防止并发 decrypt 导致 nonce 乱序
    final prev = _recvLock;
    final completer = Completer<void>();
    _recvLock = completer.future;

    await prev;
    try {
      final frame = decodeFrame(raw);
      if (frame.t != FrameType.data) return;

      if (_noiseSession == null || !_noiseSession!.ready) return;
      final plaintext = await _noiseSession!.decrypt(frame.payload);
      final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;

      _lastActivity = DateTime.now();

      switch (json['type']) {
        case 'message':
          final msg = PeerMessage.fromWireJson(
            json['payload'] as Map<String, dynamic>,
            peer.id,
          );
          _messageController.add(msg);
          // 自动回复已送达回执（不 await，避免阻塞接收）
          _sendAck(msg.id, 'delivered');
          break;

        case 'ack':
          final messageId = json['message_id'] as String;
          final status = json['status'] as String;
          _ackController.add(PeerAckEvent(messageId: messageId, status: status));
          break;

        case 'ping':
          _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
            'type': 'pong',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }))));
          break;

        case 'pong':
          break;
      }
    } catch (e) {
      _log.error('Error handling incoming frame', tag: _tag, error: e);
    } finally {
      completer.complete();
    }
  }

  /// 发送投递回执
  Future<void> _sendAck(String messageId, String status) async {
    await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'ack',
      'message_id': messageId,
      'status': status,
    }))));
  }

  /// 发送已读回执（批量）
  Future<void> sendReadReceipts(List<String> messageIds) async {
    for (final id in messageIds) {
      await _sendAck(id, 'read');
    }
  }

  void _send(String frameStr) {
    if (_wsChannel != null) {
      _wsChannel!.sink.add(frameStr);
    } else if (_tunnelStream != null && !_tunnelStream!.isClosed) {
      _tunnelStream!.send(Uint8List.fromList(utf8.encode(frameStr)));
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // 检查超时（90s 无活动）
      if (_lastActivity != null &&
          DateTime.now().difference(_lastActivity!) > const Duration(seconds: 90)) {
        _log.warning('Heartbeat timeout for ${peer.deviceName}', tag: _tag);
        _setState(PeerConnectionState.disconnected);
        _heartbeatTimer?.cancel();
        return;
      }
      _sendHeartbeat();
    });
    _lastActivity = DateTime.now();
  }

  void _setState(PeerConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }
}

/// 回执事件
class PeerAckEvent {
  final String messageId;
  final String status; // 'delivered' or 'read'
  PeerAckEvent({required this.messageId, required this.status});
}
