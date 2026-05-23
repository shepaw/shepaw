/// P2P 连接管理器
///
/// 管理与所有已配对设备的连接生命周期：
/// - 自动重连已配对设备
/// - 处理入站连接（来自 PeerChannelBridge）
/// - 消息路由和广播
/// - 离线消息队列
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../services/noise_identity.dart';
import '../../services/noise/noise_session.dart';
import '../../services/noise/noise_envelope.dart';
import '../../services/logger_service.dart';
import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import 'peer_connection.dart';
import 'peer_channel_bridge.dart';
import 'peer_local_server.dart';
import 'peer_pairing_service.dart';
import 'peer_storage_service.dart';

/// P2P 连接管理器（单例）
class PeerConnectionManager {
  PeerConnectionManager._();
  static final PeerConnectionManager instance = PeerConnectionManager._();

  static const _tag = 'PeerConnMgr';
  final _log = LoggerService();
  final _storage = PeerStorageService();

  /// 活跃连接（peerId → PeerConnection）
  final Map<String, PeerConnection> _connections = {};

  /// 重连定时器（peerId → Timer）
  final Map<String, Timer> _reconnectTimers = {};

  /// 重连尝试次数（peerId → count）
  final Map<String, int> _reconnectAttempts = {};

  /// 入站连接监听（Channel 隧道）
  StreamSubscription? _bridgeSub;

  /// 入站连接监听（本地网络）
  StreamSubscription? _localSub;

  /// 是否已启动
  bool _running = false;

  // ── 事件流 ──────────────────────────────────────────────────────────

  /// 所有 peer 的消息流
  final _messageController = StreamController<PeerMessage>.broadcast();
  Stream<PeerMessage> get messages => _messageController.stream;

  /// 连接状态变化事件
  final _eventController = StreamController<PeerConnectionEvent>.broadcast();
  Stream<PeerConnectionEvent> get events => _eventController.stream;

  // ── 公开 API ─────────────────────────────────────────────────────────

  /// 启动管理器：加载所有已配对设备，尝试重连，监听入站连接
  Future<void> start() async {
    if (_running) return;
    _running = true;

    await _storage.ensureTables();

    // 确保本地 P2P 服务器运行（接收入站连接）
    if (!PeerLocalServer.instance.isRunning) {
      try {
        await PeerLocalServer.instance.start();
      } catch (e) {
        _log.warning('Failed to start local P2P server: $e', tag: _tag);
      }
    }

    // 监听入站连接（仅注册一次）
    _bridgeSub ??= PeerChannelBridge.instance.incomingConnections.listen(
      _handleIncomingConnection,
    );
    _localSub ??= PeerLocalServer.instance.incomingConnections.listen(
      _handleIncomingConnection,
    );

    // 加载所有已配对设备，尝试连接
    final peers = await _storage.loadAllPeers();
    for (final peer in peers) {
      if (!peer.isBlocked) {
        _scheduleReconnect(peer, delay: Duration.zero);
      }
    }

    _log.info('PeerConnectionManager started, ${peers.length} peers loaded', tag: _tag);
  }

  /// 停止管理器：断开所有连接
  Future<void> stop() async {
    _running = false;
    _bridgeSub?.cancel();
    _bridgeSub = null;
    _localSub?.cancel();
    _localSub = null;

    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();

    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();

    _log.info('PeerConnectionManager stopped', tag: _tag);
  }

  /// 获取所有已配对设备（含实时连接状态）
  Future<List<PairedPeer>> getAllPeers() async {
    // 确保表已创建
    await _storage.ensureTables();
    final peers = await _storage.loadAllPeers();
    return peers.map((p) {
      final conn = _connections[p.id];
      if (conn != null) {
        return p.copyWith(state: conn.state);
      }
      return p;
    }).toList();
  }

  /// 主动连接指定 peer（自动确保管理器已启动）
  Future<void> connectToPeer(PairedPeer peer) async {
    // 确保管理器已启动（监听入站连接 + 本地服务器运行）
    await start();

    if (_connections.containsKey(peer.id) &&
        _connections[peer.id]!.state == PeerConnectionState.connected) {
      return; // 已连接
    }

    await _doConnect(peer);
  }

  /// 断开与指定 peer 的连接
  Future<void> disconnectPeer(String peerId) async {
    _reconnectTimers[peerId]?.cancel();
    _reconnectTimers.remove(peerId);
    _reconnectAttempts.remove(peerId);

    final conn = _connections.remove(peerId);
    if (conn != null) {
      await conn.close();
      _eventController.add(PeerConnectionEvent(
        peerId: peerId,
        type: PeerConnectionEventType.disconnected,
      ));
    }
  }

  /// 发送消息给指定 peer
  Future<void> sendMessage(String peerId, PeerMessage message) async {
    final conn = _connections[peerId];
    if (conn != null && conn.state == PeerConnectionState.connected) {
      await conn.sendMessage(message);
      // 更新消息状态为已发送
      await _storage.updateMessageDelivery(message.id, PeerMessageDelivery.sent);
    } else {
      // 离线，保存到待发队列
      await _storage.saveMessage(message.copyWith(
        delivery: PeerMessageDelivery.pending,
      ));
    }
  }

  /// 删除配对并断开连接
  Future<void> removePeer(String peerId) async {
    await disconnectPeer(peerId);
    await _storage.removePeer(peerId);
    _log.info('Peer removed: $peerId', tag: _tag);
  }

  /// 获取指定 peer 的连接状态
  PeerConnectionState getPeerState(String peerId) {
    return _connections[peerId]?.state ?? PeerConnectionState.disconnected;
  }

  // ── 内部方法 ────────────────────────────────────────────────────────

  /// 处理来自 PeerChannelBridge 或 PeerLocalServer 的入站连接
  void _handleIncomingConnection(PeerTunnelStream stream) async {
    _log.info('Incoming peer connection, stream=${stream.streamId}', tag: _tag);

    // 如果 PeerPairingService 正在配对中，由它处理
    if (PeerPairingService.instance.state == PairingSessionState.waitingForScanner) {
      _log.debug('Pairing in progress, delegating to PairingService', tag: _tag);
      return;
    }

    // 已配对设备的重连：执行 Responder 握手，根据公钥匹配 peer
    try {
      await _acceptIncomingConnection(stream);
    } catch (e) {
      _log.error('Failed to accept incoming connection', tag: _tag, error: e);
      stream.close();
    }
  }

  /// 接受入站连接：执行 Responder 握手，匹配已知 peer
  Future<void> _acceptIncomingConnection(PeerTunnelStream stream) async {
    final allPeers = await _storage.loadAllPeers();
    if (allPeers.isEmpty) {
      _log.debug('No paired peers, rejecting incoming connection', tag: _tag);
      stream.close();
      return;
    }

    // 执行 Noise Responder 握手以获取对方公钥
    final identity = await NoiseIdentity.loadOrCreate();
    final noiseSession = await NoiseSession.responder(
      staticPublicKey: identity.publicKey,
      staticPrivateKey: identity.privateKey,
    );

    // 用 Completer 方式取第一条消息，保持 subscription 活跃
    final firstMsgCompleter = Completer<Uint8List>();
    final bufferedMessages = <Uint8List>[];
    var firstReceived = false;

    final sub = stream.incoming.listen(
      (data) {
        if (!firstReceived) {
          firstReceived = true;
          firstMsgCompleter.complete(data);
        } else {
          bufferedMessages.add(data);
        }
      },
      onError: (e) {
        if (!firstMsgCompleter.isCompleted) {
          firstMsgCompleter.completeError(e);
        }
      },
      onDone: () {
        if (!firstMsgCompleter.isCompleted) {
          firstMsgCompleter.completeError(StateError('Stream closed before msg1'));
        }
      },
    );

    Uint8List msg1Raw;
    try {
      msg1Raw = await firstMsgCompleter.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      noiseSession.close();
      await sub.cancel();
      stream.close();
      rethrow;
    }

    final msg1Frame = decodeFrame(utf8.decode(msg1Raw));
    if (msg1Frame.t != FrameType.hs) {
      noiseSession.close();
      await sub.cancel();
      stream.close();
      return;
    }

    final result = await noiseSession.readHandshake1(msg1Frame.payload);
    final peerPublicKey = result.peerStaticPublicKey;

    // 通过公钥匹配已配对设备
    PairedPeer? matchedPeer;
    for (final p in allPeers) {
      if (_keysEqual(p.publicKey, peerPublicKey)) {
        matchedPeer = p;
        break;
      }
    }

    if (matchedPeer == null || matchedPeer.isBlocked) {
      _log.warning('Incoming connection from unknown/blocked peer, rejecting', tag: _tag);
      noiseSession.close();
      await sub.cancel();
      stream.close();
      return;
    }

    // 发送 msg2 完成握手
    final msg2Payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'reconnect_ack',
      'device_id': identity.fingerprintHex,
    })));
    final msg2 = await noiseSession.writeHandshake2(msg2Payload);
    final frame2 = encodeFrame(Frame(t: FrameType.hs, payload: msg2));
    stream.send(Uint8List.fromList(utf8.encode(frame2)));

    // 取消原始 subscription，创建新的 broadcast stream 供 PeerConnection 使用
    await sub.cancel();

    // 重建一个 stream 包装器：将 PeerTunnelStream 转为可重新监听的形式
    // 使用 broadcast controller 转发后续消息
    final relayCtrl = StreamController<Uint8List>.broadcast();
    stream.incoming.listen(
      (data) => relayCtrl.add(data),
      onDone: () => relayCtrl.close(),
      onError: (e) => relayCtrl.addError(e),
    );
    // 先把 buffer 中的消息推入
    for (final msg in bufferedMessages) {
      relayCtrl.add(msg);
    }

    // 握手完成 — 关闭旧连接，注册新连接
    final oldConn = _connections.remove(matchedPeer.id);
    if (oldConn != null) await oldConn.close();
    _reconnectTimers[matchedPeer.id]?.cancel();

    final conn = PeerConnection.fromEstablishedSession(
      peer: matchedPeer,
      noiseSession: noiseSession,
      tunnelStream: stream,
      incomingStream: relayCtrl.stream,
    );
    _connections[matchedPeer.id] = conn;

    // 监听（用局部 final 变量避免 closure 中的 null 检查）
    final peerId = matchedPeer.id;
    final peerForReconnect = matchedPeer;
    conn.messages.listen((msg) {
      _messageController.add(msg);
      _storage.saveMessage(msg);
      _eventController.add(PeerConnectionEvent(
        peerId: peerId,
        type: PeerConnectionEventType.messageReceived,
        data: msg,
      ));
    });
    conn.stateChanges.listen((state) {
      _eventController.add(PeerConnectionEvent(
        peerId: peerId,
        type: state == PeerConnectionState.connected
            ? PeerConnectionEventType.connected
            : PeerConnectionEventType.disconnected,
      ));
      if (state == PeerConnectionState.disconnected && _running) {
        _scheduleReconnect(peerForReconnect);
      }
    });

    _eventController.add(PeerConnectionEvent(
      peerId: matchedPeer.id,
      type: PeerConnectionEventType.connected,
    ));
    _storage.updateLastSeen(matchedPeer.id, DateTime.now().millisecondsSinceEpoch);
    _flushPendingMessages(matchedPeer.id);

    _log.info('Accepted reconnection from ${matchedPeer.deviceName}', tag: _tag);
  }

  bool _keysEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// 从 localEndpoint URL 中提取 IP 地址
  /// 例如 "ws://192.168.31.79:44315/peer/ws" → "192.168.31.79"
  String? _extractLocalAddress(String? localEndpoint) {
    if (localEndpoint == null) return null;
    try {
      final uri = Uri.parse(localEndpoint);
      final host = uri.host;
      if (host.isEmpty || host == '127.0.0.1' || host == 'localhost') return null;
      return host;
    } catch (_) {
      return null;
    }
  }

  /// 执行连接（优先内网直连，失败后回退 Channel）
  Future<void> _doConnect(PairedPeer peer) async {
    try {
      final conn = PeerConnection(peer: peer);
      _connections[peer.id] = conn;

      // 监听消息
      conn.messages.listen((msg) {
        _messageController.add(msg);
        _storage.saveMessage(msg);
        _eventController.add(PeerConnectionEvent(
          peerId: peer.id,
          type: PeerConnectionEventType.messageReceived,
          data: msg,
        ));
      });

      // 监听状态
      conn.stateChanges.listen((state) {
        if (state == PeerConnectionState.disconnected) {
          _eventController.add(PeerConnectionEvent(
            peerId: peer.id,
            type: PeerConnectionEventType.disconnected,
          ));
          // 自动重连
          if (_running) {
            _scheduleReconnect(peer);
          }
        } else if (state == PeerConnectionState.connected) {
          _reconnectAttempts.remove(peer.id);
          _eventController.add(PeerConnectionEvent(
            peerId: peer.id,
            type: PeerConnectionEventType.connected,
          ));
          _storage.updateLastSeen(peer.id, DateTime.now().millisecondsSinceEpoch);
          // 发送离线消息队列
          _flushPendingMessages(peer.id);
        }
      });

      // 优先内网直连，失败回退 Channel
      bool connected = false;

      // 尝试内网直连：从存储的 localEndpoint 提取 IP，使用固定端口
      final localAddr = _extractLocalAddress(peer.localEndpoint);
      if (localAddr != null) {
        // 先尝试固定端口
        final fixedUrl = 'ws://$localAddr:${PeerLocalServer.defaultPort}/peer/ws';
        try {
          await conn.connectViaWebSocket(fixedUrl);
          connected = true;
          _log.debug('Connected to ${peer.deviceName} via local network (fixed port)', tag: _tag);
        } catch (e) {
          _log.debug('Fixed port connection failed: $e', tag: _tag);
          // 回退到存储的完整 localEndpoint（可能有正确的随机端口）
          if (peer.localEndpoint != null && peer.localEndpoint != fixedUrl) {
            try {
              await conn.connectViaWebSocket(peer.localEndpoint!);
              connected = true;
              _log.debug('Connected to ${peer.deviceName} via local network (stored port)', tag: _tag);
            } catch (e2) {
              _log.debug('Stored port connection also failed: $e2', tag: _tag);
            }
          }
        }
      }

      if (!connected && peer.channelEndpoint != null) {
        try {
          await conn.connectViaWebSocket(peer.channelEndpoint!);
          connected = true;
          _log.debug('Connected to ${peer.deviceName} via channel relay', tag: _tag);
        } catch (e) {
          _log.debug('Channel connection to ${peer.deviceName} failed: $e', tag: _tag);
        }
      }

      if (!connected) {
        throw StateError('No available endpoint for ${peer.deviceName}');
      }

    } catch (e) {
      _log.warning('Failed to connect to ${peer.deviceName}: $e', tag: _tag);
      _connections.remove(peer.id);
      // 重连
      if (_running) {
        _scheduleReconnect(peer);
      }
    }
  }

  /// 调度重连
  void _scheduleReconnect(PairedPeer peer, {Duration? delay}) {
    _reconnectTimers[peer.id]?.cancel();

    final attempts = _reconnectAttempts[peer.id] ?? 0;
    if (attempts >= 10) {
      _log.warning('Max reconnect attempts reached for ${peer.deviceName}', tag: _tag);
      return;
    }

    // 指数退避: 2s, 4s, 8s, 16s, 32s, 60s max
    final backoffSeconds = delay?.inSeconds ?? (2 * (1 << attempts)).clamp(2, 60);
    final actualDelay = delay ?? Duration(seconds: backoffSeconds);

    _reconnectTimers[peer.id] = Timer(actualDelay, () async {
      if (!_running) return;
      _reconnectAttempts[peer.id] = attempts + 1;
      _log.debug('Reconnecting to ${peer.deviceName} (attempt ${attempts + 1})', tag: _tag);
      await _doConnect(peer);
    });
  }

  /// 发送离线消息队列
  Future<void> _flushPendingMessages(String peerId) async {
    final pending = await _storage.getPendingMessages(peerId);
    if (pending.isEmpty) return;

    _log.info('Flushing ${pending.length} pending messages to $peerId', tag: _tag);
    final conn = _connections[peerId];
    if (conn == null || conn.state != PeerConnectionState.connected) return;

    for (final msg in pending) {
      try {
        await conn.sendMessage(msg);
        await _storage.updateMessageDelivery(msg.id, PeerMessageDelivery.sent);
      } catch (e) {
        _log.warning('Failed to flush message ${msg.id}: $e', tag: _tag);
        break; // 停止发送，等下次连接
      }
    }
  }

  void dispose() {
    stop();
    _messageController.close();
    _eventController.close();
  }
}
