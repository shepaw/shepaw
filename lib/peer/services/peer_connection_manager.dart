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

import 'package:meta/meta.dart';

import '../../services/noise_identity.dart';
import '../../services/noise/noise_session.dart';
import '../../services/noise/noise_envelope.dart';
import '../../services/channel_tunnel_service.dart';
import '../../services/logger_service.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
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

  /// 正在进行的主动连接尝试（peerId 集合）
  /// 防止重入：避免新的 _doConnect 把仍在握手/建连中的连接掐掉后重头再来，
  /// 否则配对后多个触发点（UI / 重连定时器 / 生命周期）会互相打断，导致一直连不上。
  final Set<String> _connecting = {};

  /// 活跃连接的事件订阅（peerId → subscriptions）
  /// 连接被替换或断开时取消，防止旧连接的回调泄漏
  final Map<String, List<StreamSubscription>> _connectionSubs = {};

  /// 重连定时器（peerId → Timer）
  final Map<String, Timer> _reconnectTimers = {};

  /// Tie-break 回退定时器（peerId → Timer）
  final Map<String, Timer> _fallbackTimers = {};

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

  /// 回执事件流（消息状态更新：delivered / read）
  final _ackController = StreamController<PeerAckEvent>.broadcast();
  Stream<PeerAckEvent> get ackEvents => _ackController.stream;

  /// 控制消息事件流（agent-over-peer）。供 host/client 服务订阅。
  final _controlController = StreamController<PeerControlEvent>.broadcast();
  Stream<PeerControlEvent> get controlEvents => _controlController.stream;

  /// 连接状态变化事件
  final _eventController = StreamController<PeerConnectionEvent>.broadcast();
  Stream<PeerConnectionEvent> get events => _eventController.stream;

  /// peer 列表变化事件（新增配对 / 删除配对 / 连接建立）——供会话列表、设备列表刷新。
  /// 与 [events] 区分：events 关注单个连接状态，这里关注「集合发生增删」。
  final _peerListChangedController = StreamController<void>.broadcast();
  Stream<void> get peerListChanged => _peerListChangedController.stream;

  /// 主动通知 peer 列表发生变化（如配对成功保存后）。
  void notifyPeerListChanged() {
    if (!_peerListChangedController.isClosed) {
      _peerListChangedController.add(null);
    }
  }

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
    for (final timer in _fallbackTimers.values) {
      timer.cancel();
    }
    _fallbackTimers.clear();
    _reconnectAttempts.clear();
    _connecting.clear();

    for (final subs in _connectionSubs.values) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    _connectionSubs.clear();

    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();

    _log.info('PeerConnectionManager stopped', tag: _tag);
  }

  /// App 恢复前台时调用 — 主动重连所有 peer。
  ///
  /// [backgroundedFor] 为本次后台停留时长。移动系统在较长时间后台会挂起 / 关闭
  /// 套接字，使现有连接变成「半开」陈旧连接（状态仍是 connected 但实际已失效）。
  /// 因此后台较久时强制刷新连接。
  ///
  /// 刚恢复的一方此前很可能不可达（息屏 / 后台），对端无法连入，所以这里一律由
  /// 本机「主动发起」连接（ignoreTieBreak），重复连接交给 glare 收敛器处理。
  Future<void> resumeAll({Duration? backgroundedFor}) async {
    if (!_running) {
      await start();
      return;
    }
    final forceRefresh = backgroundedFor == null ||
        backgroundedFor > const Duration(seconds: 20);
    _log.info(
      'Resuming peer connections (forceRefresh=$forceRefresh, '
      'bg=${backgroundedFor?.inSeconds ?? '?'}s)',
      tag: _tag,
    );
    final peers = await _storage.loadAllPeers();
    for (final peer in peers) {
      if (peer.isBlocked) continue;
      final conn = _connections[peer.id];
      final isConnected =
          conn != null && conn.state == PeerConnectionState.connected;
      // 短暂后台且仍连接 → 大概率有效，保留，不打断
      if (isConnected && !forceRefresh) continue;

      // 取消遗留定时器、重置退避，准备立即主动发起
      _reconnectTimers[peer.id]?.cancel();
      _reconnectTimers.remove(peer.id);
      _fallbackTimers[peer.id]?.cancel();
      _fallbackTimers.remove(peer.id);
      _reconnectAttempts.remove(peer.id);

      // 关闭可能已半开失效的旧连接，强制重建（否则 _doConnect 会因「已连接」跳过）
      if (isConnected) {
        _connections.remove(peer.id);
        _cancelConnectionSubs(peer.id);
        await conn.close();
      }

      // 主动发起（忽略 tie-break）。不 await，让各 peer 并发连接。
      _doConnect(peer, ignoreTieBreak: true);
    }
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
    _cancelConnectionSubs(peerId);

    final conn = _connections.remove(peerId);
    if (conn != null) {
      await conn.close();
      _eventController.add(PeerConnectionEvent(
        peerId: peerId,
        type: PeerConnectionEventType.disconnected,
      ));
    }
  }

  /// 发送消息给指定 peer。
  ///
  /// - 在线且发送成功 → 标记 sent 并广播 sent 事件（UI 单勾）。
  /// - 在线但发送失败（半开连接 / 会话未就绪）→ 标记 pending 并触发立即重连。
  /// - 离线 → 入待发队列并触发立即重连。
  ///
  /// 待发队列中的消息会在连接恢复后由 [_flushPendingMessages] 自动补发。
  Future<void> sendMessage(String peerId, PeerMessage message) async {
    final conn = _connections[peerId];
    if (conn != null && conn.state == PeerConnectionState.connected) {
      try {
        await conn.sendMessage(message);
        await _storage.updateMessageDelivery(message.id, PeerMessageDelivery.sent);
        _emitLocalDelivery(message.id, 'sent');
      } catch (e) {
        // 发送失败（如 WiFi 刚断、连接半开）：保留为待发队列，主动重连后补发
        _log.warning('sendMessage failed, queuing: $e', tag: _tag);
        await _storage.updateMessageDelivery(message.id, PeerMessageDelivery.pending);
        _triggerImmediateReconnect(peerId);
      }
    } else {
      // 离线，保存到待发队列，并主动尝试重连以尽快补发
      await _storage.saveMessage(message.copyWith(
        delivery: PeerMessageDelivery.pending,
      ));
      _triggerImmediateReconnect(peerId);
    }
  }

  /// 广播本地投递状态变化（如发送成功 / 补发成功），供打开的聊天页更新气泡状态。
  /// 复用 ack 事件流，status 取值与回执一致（'sent' / 'delivered' / 'read'）。
  void _emitLocalDelivery(String messageId, String status) {
    if (!_ackController.isClosed) {
      _ackController.add(PeerAckEvent(messageId: messageId, status: status));
    }
  }

  /// 主动触发一次立即重连（重置退避），用于「无法发送时尽快恢复连接」。
  /// 若已连接或正在连接中则跳过，避免打断正在进行的握手。
  Future<void> _triggerImmediateReconnect(String peerId) async {
    if (!_running) return;
    final conn = _connections[peerId];
    if (conn != null && conn.state == PeerConnectionState.connected) return;
    if (_connecting.contains(peerId)) return;
    final peer = await _storage.getPeerById(peerId);
    if (peer == null || peer.isBlocked) return;
    _reconnectAttempts.remove(peerId);
    _scheduleReconnect(peer, delay: Duration.zero);
  }

  /// 发送控制消息给指定 peer（agent-over-peer）。
  ///
  /// 返回是否成功发出（peer 未连接时返回 false，不入队）。控制消息是
  /// 请求/响应式的，离线排队没有意义。
  @visibleForTesting
  static Future<bool> Function(String peerId, Map<String, dynamic> json)?
      debugSendControlOverride;

  @visibleForTesting
  static PeerConnectionState Function(String peerId)? debugGetPeerStateOverride;

  Future<bool> sendControl(String peerId, Map<String, dynamic> json) async {
    final override = debugSendControlOverride;
    if (override != null) {
      return override(peerId, json);
    }
    final conn = _connections[peerId];
    if (conn != null && conn.state == PeerConnectionState.connected) {
      try {
        await conn.sendControl(json);
        return true;
      } catch (e) {
        _log.warning('sendControl failed: $e', tag: _tag);
        return false;
      }
    }
    return false;
  }

  /// 当前已连接的 peerId 列表。
  List<String> get connectedPeerIds => _connections.entries
      .where((e) => e.value.state == PeerConnectionState.connected)
      .map((e) => e.key)
      .toList();

  /// 标记消息已读并发送已读回执给对方
  Future<void> markMessagesAsRead(String peerId, List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final conn = _connections[peerId];
    if (conn != null && conn.state == PeerConnectionState.connected) {
      await conn.sendReadReceipts(messageIds);
    }
    // 不管是否在线，本地都标记已读
    for (final id in messageIds) {
      await _storage.updateMessageDelivery(id, PeerMessageDelivery.read);
    }
  }

  /// 删除配对并断开连接
  Future<void> removePeer(String peerId) async {
    await disconnectPeer(peerId);
    await _storage.removePeer(peerId);
    // 清理重连/回退状态，避免删除后又被定时器拉起
    _reconnectTimers.remove(peerId)?.cancel();
    _fallbackTimers.remove(peerId)?.cancel();
    _reconnectAttempts.remove(peerId);
    _connecting.remove(peerId);
    _log.info('Peer removed: $peerId', tag: _tag);
    notifyPeerListChanged();
  }

  /// 获取指定 peer 的连接状态
  PeerConnectionState getPeerState(String peerId) {
    final override = debugGetPeerStateOverride;
    if (override != null) {
      return override(peerId);
    }
    return _connections[peerId]?.state ?? PeerConnectionState.disconnected;
  }

  // ── 内部方法 ────────────────────────────────────────────────────────

  /// 处理来自 PeerChannelBridge 或 PeerLocalServer 的入站连接
  void _handleIncomingConnection(PeerTunnelStream stream) async {
    _log.info('Incoming peer connection, stream=${stream.streamId}', tag: _tag);

    // 配对入站由 PeerPairingService 独占处理，避免误走重连握手。
    if (PeerPairingService.instance.isHandlingIncomingPairing) {
      _log.debug('Pairing in progress, delegating to PairingService', tag: _tag);
      unawaited(PeerPairingService.instance.handleIncomingPeerStream(stream));
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

    // 单一 subscription + relay controller 方案：
    // listen 回调通过闭包变量 `onData` 动态切换行为。
    // 使用普通（非 broadcast）controller：在 PeerConnection 订阅前到达的帧会被
    // 缓冲而非丢弃，避免握手完成瞬间对端立即发数据时丢首帧。
    final relayCtrl = StreamController<Uint8List>();
    final firstMsgCompleter = Completer<Uint8List>();
    var handshakeDone = false;

    final sub = stream.incoming.listen(
      (data) {
        if (!handshakeDone) {
          // 握手阶段：第一条消息交给 completer
          if (!firstMsgCompleter.isCompleted) {
            firstMsgCompleter.complete(data);
          }
          // 握手期间如果有多余消息（不太可能），暂存到 relay
          else {
            relayCtrl.add(data);
          }
        } else {
          // 握手完成后：所有数据转发到 relay
          relayCtrl.add(data);
        }
      },
      onError: (e) {
        if (!firstMsgCompleter.isCompleted) {
          firstMsgCompleter.completeError(e);
        }
        relayCtrl.addError(e);
      },
      onDone: () {
        if (!firstMsgCompleter.isCompleted) {
          firstMsgCompleter.completeError(StateError('Stream closed before msg1'));
        }
        relayCtrl.close();
      },
    );

    // 等待 msg1
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

    // 扫码配对请求（含 pairing_code）只能由 PeerPairingService 处理。
    try {
      final payload = jsonDecode(utf8.decode(result.msg1Payload)) as Map<String, dynamic>;
      if (payload.containsKey('pairing_code')) {
        _log.debug(
          'Pairing request received while pairing UI inactive, sending reject',
          tag: _tag,
        );
        final pairing = PeerPairingService.instance;
        await pairing.ensureDeviceInfo();
        final rejectResponse = PairingResponse(
          accepted: false,
          deviceName: await pairing.getDeviceName(),
          deviceId: await pairing.getDeviceId(),
          peerId: '',
          rejectReason: '主存储设备未处于扫码配对状态，请重新打开二维码页面',
        );
        final msg2 = await noiseSession.writeHandshake2(rejectResponse.toBytes());
        final frame2 = encodeFrame(Frame(t: FrameType.hs, payload: msg2));
        stream.send(Uint8List.fromList(utf8.encode(frame2)));
        noiseSession.close();
        await sub.cancel();
        stream.close();
        return;
      }
    } catch (_) {}

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

    // 学习并持久化对端当前内网地址：换网 / 重连 WiFi 后对端 IP 常会变化，
    // 存储里的旧 localEndpoint 会失效，导致本机主动直连一直超时。每次对端连入时
    // 用其实际来源 IP 刷新 localEndpoint，使后续本机主动直连能命中正确地址。
    final learnedAddr = stream.remoteAddress;
    if (learnedAddr != null && learnedAddr.isNotEmpty) {
      final learnedEndpoint =
          'ws://$learnedAddr:${PeerLocalServer.defaultPort}/peer/ws';
      if (learnedEndpoint != matchedPeer.localEndpoint) {
        await _storage.updateLocalEndpoint(matchedPeer.id, learnedEndpoint);
        matchedPeer = matchedPeer.copyWith(localEndpoint: learnedEndpoint);
        _log.debug(
          'Learned local endpoint for ${matchedPeer.deviceName}: $learnedEndpoint',
          tag: _tag,
        );
      }
    }

    // 重复连接（glare）的确定性收敛 vs. 陈旧半开连接的替换：
    //
    // - 真正的「双向同时建连(glare)」：两端几乎同时互相主动发起，此时本机的
    //   _connecting 集合里一定有该 peer（自己正在发起 outbound）。这种情况下由
    //   「指定发起方」(指纹较小者) 坚持自己的 outbound、拒绝对端 inbound；两端用
    //   同一把尺、计算结果互补，必然收敛到同一条连接。
    //
    // - 「陈旧半开连接」：本机并未在发起连接（_connecting 不含该 peer），只是握着
    //   一条状态仍是 connected、实则已失效的旧连接（切网 / 对端息屏后常见）。对端
    //   此刻主动连入，说明对端已认定旧连接死亡。若仍以「我是指定发起方」为由拒绝
    //   入站、死守旧连接，就会陷入「标题显示已连接、却一直拒绝对端、收不到消息」的
    //   死循环（旧连接要等 120s 活性超时才会被清掉）。因此这种情况必须接受入站、
    //   替换旧连接。
    //
    // 用 _connecting 区分二者：仅当「我此刻正在主动发起对该 peer 的连接」时才视为
    // 真 glare、由指定发起方拒绝入站；否则一律接受入站并替换可能已失效的旧连接。
    final iAmInitiator = _isDesignatedInitiator(
      identity.fingerprintHex,
      matchedPeer.fingerprint,
    );
    final iAmActivelyConnecting = _connecting.contains(matchedPeer.id);
    if (iAmInitiator && iAmActivelyConnecting) {
      _log.debug(
        'Glare with ${matchedPeer.deviceName}: keep my outbound, reject inbound '
        '(designated initiator & actively connecting)',
        tag: _tag,
      );
      noiseSession.close();
      await sub.cancel();
      stream.close();
      return;
    }
    // 其余情况一律接受入站：旧连接（可能已半开失效）会在注册新连接前被关闭。

    // 发送 msg2 完成握手
    final msg2Payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'reconnect_ack',
      'device_id': identity.fingerprintHex,
    })));
    final msg2 = await noiseSession.writeHandshake2(msg2Payload);
    final frame2 = encodeFrame(Frame(t: FrameType.hs, payload: msg2));
    stream.send(Uint8List.fromList(utf8.encode(frame2)));

    // 标记握手完成 — 后续数据通过 relay 转发给 PeerConnection
    handshakeDone = true;

    // 关闭旧连接，注册新连接
    final oldConn = _connections.remove(matchedPeer.id);
    if (oldConn != null) await oldConn.close();
    _reconnectTimers[matchedPeer.id]?.cancel();
    _fallbackTimers[matchedPeer.id]?.cancel();
    _fallbackTimers.remove(matchedPeer.id);

    final conn = PeerConnection.fromEstablishedSession(
      peer: matchedPeer,
      noiseSession: noiseSession,
      tunnelStream: stream,
      incomingStream: relayCtrl.stream,
    );
    _connections[matchedPeer.id] = conn;
    _wireConnection(conn, matchedPeer);

    // 连接创建时已是 connected 状态，stateChanges 不会再发出 connected 事件，
    // 因此在此手动触发连接建立后的副作用（发事件、更新 lastSeen、补发离线消息）。
    _onConnected(matchedPeer);

    _log.info('Accepted reconnection from ${matchedPeer.deviceName}', tag: _tag);
  }

  /// 统一连线：订阅连接的消息 / 回执 / 状态流，并跟踪 subscription 以便取消。
  /// 入站接受与主动连接两条路径共用，避免重复代码。
  void _wireConnection(PeerConnection conn, PairedPeer peer) {
    // 取消该 peer 旧连接遗留的订阅，防止泄漏
    _cancelConnectionSubs(peer.id);

    final subs = <StreamSubscription>[
      conn.messages.listen((msg) {
        _messageController.add(msg);
        _storage.saveMessage(msg);
        _eventController.add(PeerConnectionEvent(
          peerId: peer.id,
          type: PeerConnectionEventType.messageReceived,
          data: msg,
        ));
      }),
      conn.acks.listen((ack) {
        final delivery = ack.status == 'read'
            ? PeerMessageDelivery.read
            : PeerMessageDelivery.delivered;
        _storage.updateMessageDelivery(ack.messageId, delivery);
        _ackController.add(ack);
      }),
      conn.control.listen((json) {
        if (!_controlController.isClosed) {
          _controlController.add(PeerControlEvent(peerId: peer.id, data: json));
        }
      }),
      conn.stateChanges.listen((state) {
        if (state == PeerConnectionState.connected) {
          _onConnected(peer);
        } else if (state == PeerConnectionState.disconnected) {
          _onDisconnected(peer);
        }
      }),
    ];

    _connectionSubs[peer.id] = subs;
  }

  /// 连接建立后的副作用：重置重连状态、广播 connected 事件、更新 lastSeen、补发离线消息。
  void _onConnected(PairedPeer peer) {
    _reconnectAttempts.remove(peer.id);
    // 连接已建立，取消遗留的重连/回退定时器，避免再触发多余的 _doConnect
    // 而产生重复连接（glare）。
    _reconnectTimers[peer.id]?.cancel();
    _reconnectTimers.remove(peer.id);
    _fallbackTimers[peer.id]?.cancel();
    _fallbackTimers.remove(peer.id);
    _eventController.add(PeerConnectionEvent(
      peerId: peer.id,
      type: PeerConnectionEventType.connected,
    ));
    _storage.updateLastSeen(peer.id, DateTime.now().millisecondsSinceEpoch);
    _flushPendingMessages(peer.id);
    // 连接建立后通知列表刷新（新配对设备首次上线时即时出现在会话列表）
    notifyPeerListChanged();
  }

  /// 连接断开后的副作用：广播 disconnected 事件并在运行中时调度重连。
  void _onDisconnected(PairedPeer peer) {
    _eventController.add(PeerConnectionEvent(
      peerId: peer.id,
      type: PeerConnectionEventType.disconnected,
    ));
    if (_running) {
      _scheduleReconnect(peer);
    }
  }

  /// 取消并移除指定 peer 的连接订阅
  void _cancelConnectionSubs(String peerId) {
    final subs = _connectionSubs.remove(peerId);
    if (subs == null) return;
    for (final sub in subs) {
      sub.cancel();
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

  /// 内网端点建连超时 — 不可达时快速失败以便回退到 Channel
  static const _localConnectTimeout = Duration(seconds: 2);

  /// Tie-break responder 兜底发起延迟（可达性判断已处理主路径，这里只作安全网）
  static const _fallbackDelay = Duration(seconds: 6);

  /// 判断本机是否「公网可达」——即拥有一个对端可连入的 Channel 端点且隧道在线。
  /// 用于可达性感知的 tie-break：不可达的一方应主动发起连接。
  Future<bool> _isSelfReachable() async {
    try {
      final cfg = await ChannelTunnelService.instance.loadConfig();
      if (cfg == null) return false;
      if (ChannelTunnelService.instance.currentStatus != TunnelStatus.connected) {
        return false;
      }
      return ChannelTunnelService.instance.getPublicEndpoint(cfg) != null;
    } catch (_) {
      return false;
    }
  }

  /// 指纹收敛规则：指纹较小的一方为该 peer 的「指定发起方」。
  ///
  /// 发起 tie-break 与 glare 去重（[_acceptIncomingConnection]）共用此规则，
  /// 保证两端用同一把尺、收敛到同一条连接：指定发起方坚持自己的 outbound，
  /// 另一方接受 inbound。两端计算结果互补，必然一致。
  bool _isDesignatedInitiator(String myFingerprint, String peerFingerprint) {
    return myFingerprint.compareTo(peerFingerprint) < 0;
  }

  /// 执行连接（优先内网直连，失败后回退 Channel）
  Future<void> _doConnect(PairedPeer peer, {bool ignoreTieBreak = false}) async {
    // 使用存储中的最新端点：localEndpoint 可能已被入站连接学习并刷新为对端
    // 当前 IP，避免一直用换网前的旧地址反复超时。
    final fresh = await _storage.getPeerById(peer.id);
    if (fresh != null) peer = fresh;

    // 如果已有活跃连接，跳过
    final existing = _connections[peer.id];
    if (existing != null && existing.state == PeerConnectionState.connected) {
      return;
    }

    // 防重入：已有正在进行的连接尝试时直接返回，避免把在连的连接掐掉重来。
    // 该尝试结束后若失败会自行调度重连，无需在此处重复发起。
    if (_connecting.contains(peer.id)) {
      _log.debug('Connect already in progress for ${peer.deviceName}, skip', tag: _tag);
      return;
    }

    // 可达性感知的 tie-break：
    // - 对端可达而我方不可达 → 对端连不到我，必须由我主动发起（忽略指纹顺序）
    // - 我方可达而对端不可达 → 让对端主动连我，我仅作 fallback 兜底
    // - 两者可达性相同（都可达 / 都不可达）→ 退回指纹比较，指纹较小者发起
    if (!ignoreTieBreak) {
      final myFingerprint = (await NoiseIdentity.loadOrCreate()).fingerprintHex;
      final iAmReachable = await _isSelfReachable();
      final peerReachable = peer.channelEndpoint != null;

      final bool shouldInitiate;
      if (iAmReachable != peerReachable) {
        shouldInitiate = !iAmReachable; // 我不可达 → 我发起
      } else {
        // 可达性相同 → 用指纹收敛规则（与 glare 去重同一把尺）
        shouldInitiate = _isDesignatedInitiator(myFingerprint, peer.fingerprint);
      }

      if (!shouldInitiate) {
        _log.debug(
          'Tie-break: I am responder for ${peer.deviceName} '
          '(selfReachable=$iAmReachable, peerReachable=$peerReachable), scheduling fallback',
          tag: _tag,
        );
        _scheduleFallbackConnect(peer);
        return;
      }
    }

    // 二次检查：tie-break 期间可能有别的尝试已进入连接中
    if (_connecting.contains(peer.id)) return;
    _connecting.add(peer.id);

    PeerConnection? conn;
    try {
      conn = PeerConnection(peer: peer);
      // 关闭旧的非活跃连接
      final old = _connections.remove(peer.id);
      if (old != null) await old.close();
      _connections[peer.id] = conn;

      _wireConnection(conn, peer);

      // 优先内网直连，失败回退 Channel
      bool connected = false;

      // 尝试内网直连：从存储的 localEndpoint 提取 IP，使用固定端口
      // 内网不可达时用短超时（2s）快速失败，避免长时间阻塞 Channel 回退
      final localAddr = _extractLocalAddress(peer.localEndpoint);
      if (localAddr != null) {
        // 先尝试固定端口
        final fixedUrl = 'ws://$localAddr:${PeerLocalServer.defaultPort}/peer/ws';
        try {
          await conn.connectViaWebSocket(fixedUrl, timeout: _localConnectTimeout);
          connected = true;
          _log.debug('Connected to ${peer.deviceName} via local network (fixed port)', tag: _tag);
        } catch (e) {
          _log.debug('Fixed port connection failed: $e', tag: _tag);
          // 回退到存储的完整 localEndpoint（可能有正确的随机端口）
          if (!conn.isClosed &&
              peer.localEndpoint != null &&
              peer.localEndpoint != fixedUrl) {
            try {
              await conn.connectViaWebSocket(peer.localEndpoint!, timeout: _localConnectTimeout);
              connected = true;
              _log.debug('Connected to ${peer.deviceName} via local network (stored port)', tag: _tag);
            } catch (e2) {
              _log.debug('Stored port connection also failed: $e2', tag: _tag);
            }
          }
        }
      }

      if (!connected && !conn.isClosed && peer.channelEndpoint != null) {
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
      // 只移除属于本次 _doConnect 创建的连接（避免误删 _acceptIncoming 创建的）
      if (_connections[peer.id] == conn) {
        _connections.remove(peer.id);
        _cancelConnectionSubs(peer.id);
      }
      // 重连（但如果已有活跃连接则不重连）
      final current = _connections[peer.id];
      if (_running && (current == null || current.state != PeerConnectionState.connected)) {
        _scheduleReconnect(peer);
      }
    } finally {
      _connecting.remove(peer.id);
    }
  }

  /// Tie-break 回退：等待一段时间后，如果仍未连接，则忽略 tie-break 主动发起连接。
  /// 解决场景：tie-break 赢家无法连到我方（例如我方无 channel endpoint 或不在同一网络），
  /// 但我方可以连到对方的 channel。
  void _scheduleFallbackConnect(PairedPeer peer) {
    _fallbackTimers[peer.id]?.cancel();
    _fallbackTimers[peer.id] = Timer(_fallbackDelay, () async {
      if (!_running) return;
      // 已连接 / 正在握手（含正在接受入站）则无需回退，避免与对端发起方
      // 同时建连产生重复连接（glare）。
      final current = _connections[peer.id];
      if (current != null && current.state != PeerConnectionState.disconnected) {
        return;
      }
      if (_connecting.contains(peer.id)) return;
      _log.debug('Fallback connect: initiating connection to ${peer.deviceName}', tag: _tag);
      await _doConnect(peer, ignoreTieBreak: true);
    });
  }

  /// 调度重连
  void _scheduleReconnect(PairedPeer peer, {Duration? delay}) {
    _reconnectTimers[peer.id]?.cancel();

    final attempts = _reconnectAttempts[peer.id] ?? 0;

    // 指数退避: 2s, 4s, 8s, 16s, 30s max（不设上限次数，持续重试）
    final backoffSeconds = delay?.inSeconds ?? (2 * (1 << attempts)).clamp(2, 30);
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
        // 通知打开的聊天页将该消息从「待发送」更新为「已发送」
        _emitLocalDelivery(msg.id, 'sent');
      } catch (e) {
        _log.warning('Failed to flush message ${msg.id}: $e', tag: _tag);
        break; // 停止发送，等下次连接
      }
    }
  }

  void dispose() {
    stop();
    _messageController.close();
    _ackController.close();
    _controlController.close();
    _eventController.close();
    _peerListChangedController.close();
  }
}

/// agent-over-peer 控制消息事件（带来源 peerId）。
class PeerControlEvent {
  final String peerId;
  final Map<String, dynamic> data;
  PeerControlEvent({required this.peerId, required this.data});

  /// 控制消息类型（agent_* 之一）。
  String get type => data['type'] as String? ?? '';
}
