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

  /// 连接是否已被关闭（被新的入站连接替换或主动断开）
  bool get isClosed => _closed;

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

  /// 收到的控制消息（agent-over-peer 等非聊天控制帧）。
  /// 发出的是解密后的原始 JSON（含 `type` 字段）。
  final _controlController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get control => _controlController.stream;

  /// 走聊天持久化 / 链路自身处理的数据类 type。除这些之外的带 type 消息
  /// （agent-over-peer、account_join_*、sync_*、device_rpc_* 等）一律通过
  /// [control] 流交给上层服务，避免新增控制类型时漏配白名单导致消息被丢弃。
  static const Set<String> _dataFrameTypes = {
    'message',
    'ack',
    'ping',
    'pong',
  };

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
  ///
  /// [timeout] 控制底层 TCP/WS 建连超时。内网端点不可达时应使用较短超时
  /// （如 2s）以便快速回退到 Channel，避免长时间阻塞。
  Future<void> connectViaWebSocket(
    String endpoint, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) return;
    _setState(PeerConnectionState.connecting);

    // 清理上一次尝试遗留的订阅 / socket / 会话。connectViaWebSocket 会在同一个
    // PeerConnection 上按「固定端口 → 存储端口 → channel」顺序重试；若不清理，
    // 上一次尝试的 socket 监听器仍然活跃，而 _handleIncomingFrame 用的是实例当前
    // 的 _noiseSession（本次新建的会话）。旧 socket 上迟到的帧会被用新会话解密 →
    // NoiseTransportError: decrypt failed，并造成 socket / 订阅泄漏。
    await _incomingSub?.cancel();
    _incomingSub = null;
    try {
      await _wsChannel?.sink.close();
    } catch (_) {}
    _wsChannel = null;
    _noiseSession?.close();
    _noiseSession = null;

    try {
      final ioSocket = await io.WebSocket.connect(endpoint).timeout(timeout);
      _wsChannel = IOWebSocketChannel(ioSocket);

      // 单一 subscription：第一帧用 Completer 取 msg2 完成握手，之后继续用同一个 sub。
      //
      // 关键：握手完成（_noiseSession.ready 为 true）之前到达的数据帧必须**缓冲**而非
      // 直接交给 _handleIncomingFrame。因为对端握手后会立即补发离线消息 / 回执，这些
      // 帧会在「会话尚未就绪」的微小窗口里被 _handleIncomingFrame 因 !ready 丢弃，导致
      // 本机接收 nonce 与对端发送 nonce 错位 → 之后每一帧都 NoiseTransportError:
      // decrypt failed（确定性死循环，且恰好在「有待发消息」时触发）。
      final handshakeCompleter = Completer<String>();
      final earlyFrames = <String>[];
      _incomingSub = _wsChannel!.stream.listen(
        (data) {
          final frame = data is String ? data : utf8.decode(data as List<int>);
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.complete(frame);
          } else if (_noiseSession?.ready != true) {
            earlyFrames.add(frame);
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

      // 握手已完成、会话就绪。把握手窗口内缓冲的帧按到达顺序补放。
      // 同步逐个 invoke（不 await）：_handleIncomingFrame 内部用 _recvLock 串行化，按
      // invoke 顺序占位，保证缓冲的早到帧先于之后新到帧处理，nonce 不乱序。此处为同步
      // 循环、无 await，期间不会有新 socket 事件插入，故顺序安全。
      for (final f in earlyFrames) {
        _handleIncomingFrame(f);
      }
      earlyFrames.clear();
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

  /// 发送控制消息（agent-over-peer）。[json] 必须含 `type` 字段（agent_* 之一）。
  Future<void> sendControl(Map<String, dynamic> json) async {
    await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode(json))));
    _lastActivity = DateTime.now();
  }

  /// 发送心跳
  Future<void> _sendHeartbeat() async {
    await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'ping',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }))));
  }

  /// 回复心跳（失败静默忽略，避免中断接收处理）
  Future<void> _sendPong() async {
    try {
      await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'pong',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }))));
    } catch (e) {
      _log.debug('Failed to send pong: $e', tag: _tag);
    }
  }

  /// 序列化发送 — 确保 encrypt + send 原子执行，防止 nonce 并发冲突。
  ///
  /// 发送失败（会话未就绪 / 加密失败 / 传输层已断）会向上抛出异常，
  /// 由调用方决定如何处理（业务消息会被重新入队，心跳会触发断开重连）。
  /// 这点至关重要：若在此吞掉异常，半开连接期间发出的消息会被误判为
  /// 已发送，重连后不会补发，从而永远停留在「未送达」状态。
  Future<void> _serializedSend(Uint8List plaintext) async {
    final prev = _sendLock;
    final completer = Completer<void>();
    _sendLock = completer.future;

    await prev; // 等待上一次发送完成
    try {
      if (_noiseSession == null || !_noiseSession!.ready) {
        throw StateError('Noise session not ready');
      }
      final ciphertext = await _noiseSession!.encrypt(plaintext);
      final frame = encodeFrame(Frame(t: FrameType.data, payload: ciphertext));
      _send(frame);
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
    _controlController.close();
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

      final type = json['type'];
      if (type is String && !_dataFrameTypes.contains(type)) {
        // 控制消息：转发给上层服务（AccountJoinService / SyncProtocolService /
        // PeerAgentHost/Client 等）。未知 type 转发亦无害，对端 switch 会忽略。
        if (!_controlController.isClosed) {
          _controlController.add(json);
        }
        return;
      }

      switch (type) {
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
          // fire-and-forget；发送失败不应中断接收流程
          unawaited(_sendPong());
          break;

        case 'pong':
          break;
      }
    } catch (e) {
      _log.error('Error handling incoming frame', tag: _tag, error: e);
      // decrypt 失败意味着 Noise 会话已损坏（phase=closed），无法再收发任何帧。
      // 必须主动断开以触发上层重连、重建会话；否则连接会停留在「state=connected
      // 但会话已死」的僵尸态：发送时静默失败，而 _triggerImmediateReconnect 又因
      // 「看起来仍已连接」而跳过重连，导致消息一直发不出去。
      if (e is NoiseTransportError) {
        _heartbeatTimer?.cancel();
        _setState(PeerConnectionState.disconnected);
      }
    } finally {
      completer.complete();
    }
  }

  /// 发送投递回执（失败不致命：对端重连后会重新触发已读/送达逻辑）
  Future<void> _sendAck(String messageId, String status) async {
    try {
      await _serializedSend(Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'ack',
        'message_id': messageId,
        'status': status,
      }))));
    } catch (e) {
      _log.debug('Failed to send ack ($status) for $messageId: $e', tag: _tag);
    }
  }

  /// 发送已读回执（批量）
  Future<void> sendReadReceipts(List<String> messageIds) async {
    for (final id in messageIds) {
      await _sendAck(id, 'read');
    }
  }

  void _send(String frameStr) {
    if (_closed) {
      throw StateError('Connection closed');
    }
    if (_wsChannel != null) {
      _wsChannel!.sink.add(frameStr);
    } else if (_tunnelStream != null && !_tunnelStream!.isClosed) {
      _tunnelStream!.send(Uint8List.fromList(utf8.encode(frameStr)));
    } else {
      throw StateError('No active transport for ${peer.deviceName}');
    }
  }

  /// 心跳发送间隔。
  static const _heartbeatInterval = Duration(seconds: 30);

  /// 活性超时阈值：超过该时长未收到任何帧（含对端 pong）即判定连接已死。
  /// 取 4 个心跳周期，容忍手机短暂切后台/网络抖动，又能较快发现半开连接。
  static const _livenessTimeout = Duration(seconds: 120);

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      // 半开连接（对端消失但 TCP FIN 未到达，relay/移动网络常见）不会触发
      // onDone，必须靠活性检测主动断开。每次成功收帧都会刷新 _lastActivity，
      // 因此活连接靠 30s 一次的 pong 持续刷新；超过阈值无任何活动 → 判定已死。
      if (_lastActivity != null &&
          DateTime.now().difference(_lastActivity!) > _livenessTimeout) {
        _log.warning(
          'Heartbeat timeout (no activity ${_livenessTimeout.inSeconds}s) '
          'for ${peer.deviceName}, dropping connection',
          tag: _tag,
        );
        // 标记断开会触发上层 _onDisconnected → 调度重连，重建可用路径。
        _setState(PeerConnectionState.disconnected);
        _heartbeatTimer?.cancel();
        return;
      }
      try {
        await _sendHeartbeat();
      } catch (e) {
        // 心跳发送失败说明传输层已断（如 WiFi 关闭）。立即判定断开并触发
        // 重连，无需等待 120s 活性超时，从而更快地恢复可用连接。
        _log.warning(
          'Heartbeat send failed for ${peer.deviceName}, dropping connection: $e',
          tag: _tag,
        );
        _setState(PeerConnectionState.disconnected);
        _heartbeatTimer?.cancel();
      }
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
