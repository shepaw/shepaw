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

  /// 连接状态
  PeerConnectionState _state = PeerConnectionState.disconnected;
  PeerConnectionState get state => _state;

  /// 收到的解密消息
  final _messageController = StreamController<PeerMessage>.broadcast();
  Stream<PeerMessage> get messages => _messageController.stream;

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

      // Noise IK 握手
      await _performInitiatorHandshake();

      _setState(PeerConnectionState.connected);
      _startHeartbeat();
      _listenWebSocket();
    } catch (e) {
      _log.error('Connection failed to ${peer.deviceName}', tag: _tag, error: e);
      _setState(PeerConnectionState.disconnected);
      rethrow;
    }
  }

  /// 通过 Channel 隧道的 PeerTunnelStream 连接（Responder 侧）
  /// 用于接受来自已配对设备的入站连接
  Future<void> connectViaTunnel(PeerTunnelStream stream) async {
    if (_closed) return;
    _tunnelStream = stream;
    _setState(PeerConnectionState.connecting);

    try {
      // Noise IK 握手（Responder）
      await _performResponderHandshake(stream);

      _setState(PeerConnectionState.connected);
      _startHeartbeat();
      _listenTunnelStream(stream);
    } catch (e) {
      _log.error('Tunnel connection failed from ${peer.deviceName}', tag: _tag, error: e);
      _setState(PeerConnectionState.disconnected);
      rethrow;
    }
  }

  /// 发送加密消息
  Future<void> sendMessage(PeerMessage message) async {
    if (_noiseSession == null || !_noiseSession!.ready) {
      throw StateError('Noise session not ready');
    }

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'message',
      'payload': message.toWireJson(),
    })));

    final ciphertext = await _noiseSession!.encrypt(plaintext);
    final frame = encodeFrame(Frame(t: FrameType.data, payload: ciphertext));
    _send(frame);
    _lastActivity = DateTime.now();
  }

  /// 发送心跳
  Future<void> _sendHeartbeat() async {
    if (_noiseSession == null || !_noiseSession!.ready) return;

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'ping',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    })));

    try {
      final ciphertext = await _noiseSession!.encrypt(plaintext);
      final frame = encodeFrame(Frame(t: FrameType.data, payload: ciphertext));
      _send(frame);
    } catch (_) {
      // 心跳失败不处理，等超时检测
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
    _stateController.close();
  }

  // ── 内部方法 ────────────────────────────────────────────────────────────

  Future<void> _performInitiatorHandshake() async {
    final identity = await NoiseIdentity.loadOrCreate();
    _noiseSession = await NoiseSession.initiator(
      staticPublicKey: identity.publicKey,
      staticPrivateKey: identity.privateKey,
      pinnedPeerStaticPublicKey: peer.publicKey,
    );

    // 发送 msg1（空 payload，非配对场景）
    final msg1Payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'reconnect',
      'device_id': _getDeviceId(),
    })));
    final msg1 = await _noiseSession!.writeHandshake1(msg1Payload);
    final frame1 = encodeFrame(Frame(t: FrameType.hs, payload: msg1));
    _send(frame1);

    // 等待 msg2
    final msg2Raw = await _receiveFirst().timeout(const Duration(seconds: 15));
    final msg2Frame = decodeFrame(msg2Raw);
    if (msg2Frame.t != FrameType.hs) {
      throw StateError('Expected handshake frame, got ${msg2Frame.t}');
    }
    await _noiseSession!.readHandshake2(msg2Frame.payload);
  }

  Future<void> _performResponderHandshake(PeerTunnelStream stream) async {
    final identity = await NoiseIdentity.loadOrCreate();
    _noiseSession = await NoiseSession.responder(
      staticPublicKey: identity.publicKey,
      staticPrivateKey: identity.privateKey,
    );

    // 等待 msg1
    final msg1Raw = await stream.incoming.first.timeout(const Duration(seconds: 15));
    final msg1Frame = decodeFrame(utf8.decode(msg1Raw));
    if (msg1Frame.t != FrameType.hs) {
      throw StateError('Expected handshake frame, got ${msg1Frame.t}');
    }

    final result = await _noiseSession!.readHandshake1(msg1Frame.payload);

    // 验证对方公钥匹配已存储的
    if (!_keysEqual(result.peerStaticPublicKey, peer.publicKey)) {
      _noiseSession!.close();
      throw StateError('Peer public key mismatch — possible impersonation');
    }

    // 发送 msg2
    final msg2Payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'reconnect_ack',
      'device_id': _getDeviceId(),
    })));
    final msg2 = await _noiseSession!.writeHandshake2(msg2Payload);
    final frame2 = encodeFrame(Frame(t: FrameType.hs, payload: msg2));
    stream.send(Uint8List.fromList(utf8.encode(frame2)));
  }

  void _listenWebSocket() {
    _incomingSub = _wsChannel!.stream.listen(
      (data) => _handleIncomingFrame(data as String),
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
      (data) => _handleIncomingFrame(utf8.decode(data)),
      onDone: () {
        _log.info('Tunnel stream closed for ${peer.deviceName}', tag: _tag);
        _setState(PeerConnectionState.disconnected);
      },
    );
  }

  Future<void> _handleIncomingFrame(String raw) async {
    try {
      final frame = decodeFrame(raw);
      if (frame.t != FrameType.data) return;

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
          break;

        case 'ping':
          // 回复 pong
          final pong = Uint8List.fromList(utf8.encode(jsonEncode({
            'type': 'pong',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          })));
          final ct = await _noiseSession!.encrypt(pong);
          _send(encodeFrame(Frame(t: FrameType.data, payload: ct)));
          break;

        case 'pong':
          // 心跳确认，已更新 _lastActivity
          break;
      }
    } catch (e) {
      _log.error('Error handling incoming frame', tag: _tag, error: e);
    }
  }

  void _send(String frameStr) {
    if (_wsChannel != null) {
      _wsChannel!.sink.add(frameStr);
    } else if (_tunnelStream != null && !_tunnelStream!.isClosed) {
      _tunnelStream!.send(Uint8List.fromList(utf8.encode(frameStr)));
    }
  }

  Future<String> _receiveFirst() async {
    if (_wsChannel != null) {
      return await _wsChannel!.stream.first as String;
    }
    throw StateError('No active transport for receiving');
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

  bool _keysEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  String _getDeviceId() {
    // TODO: 从持久化存储读取
    return 'device-id';
  }
}
