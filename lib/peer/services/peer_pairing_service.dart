/// P2P 配对流程编排服务
///
/// 支持两种配对模式：
/// 1. 内网直连：同一局域网，启动本地 WS Server，QR 中含内网地址
/// 2. 外网穿透：通过 Channel 服务中继，QR 中含 Channel 端点
/// 3. 混合模式：QR 同时包含两种地址，扫描方优先尝试内网
///
/// 配对流程：
/// - QR 生成方（Responder）：等待入站连接 → 验证配对码 → 确认/拒绝
/// - QR 扫描方（Initiator）：连接对方 → 发送配对请求 → 等待确认
/// - 集成 Noise IK 握手完成端到端加密
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/noise_identity.dart';
import '../../services/noise/noise_session.dart';
import '../../services/noise/noise_envelope.dart';
import '../../services/channel_tunnel_service.dart';
import '../../services/logger_service.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import 'peer_channel_bridge.dart';
import 'peer_connection_manager.dart';
import 'peer_local_server.dart';
import 'peer_storage_service.dart';

/// 配对会话状态
enum PairingSessionState {
  idle,
  waitingForScanner,    // Responder: QR 已展示，等待对方扫描
  receivedRequest,      // Responder: 收到配对请求，等待用户确认
  waitingForConfirm,    // Initiator: 请求已发送，等待对方确认
  completed,
  failed,
  cancelled,
}

/// 收到的配对请求（展示给 Responder 用户确认）
class IncomingPairingRequest {
  final String deviceName;
  final String deviceId;
  final String fingerprint;
  final String? channelEndpoint;
  final String? localEndpoint;
  final int streamId;

  IncomingPairingRequest({
    required this.deviceName,
    required this.deviceId,
    required this.fingerprint,
    this.channelEndpoint,
    this.localEndpoint,
    required this.streamId,
  });
}

/// 配对被拒绝时的异常
class PairingRejectedException implements Exception {
  final String? reason;
  PairingRejectedException([this.reason]);
  @override
  String toString() => 'PairingRejectedException: ${reason ?? "rejected"}';
}

/// 配对超时异常
class PairingTimeoutException implements Exception {
  @override
  String toString() => 'PairingTimeoutException: pairing timed out';
}

/// P2P 配对服务（单例）
class PeerPairingService {
  PeerPairingService._();
  static final PeerPairingService instance = PeerPairingService._();

  static const _tag = 'PeerPairing';
  static const _pairingCodeLength = 6;
  static const _pairingTimeout = Duration(minutes: 5);

  final _log = LoggerService();
  final _uuid = const Uuid();
  final _storage = PeerStorageService();

  // ── 状态 ─────────────────────────────────────────────────────────────

  PairingSessionState _state = PairingSessionState.idle;
  PairingSessionState get state => _state;

  String? _currentPairingCode;
  Timer? _timeoutTimer;
  StreamSubscription? _bridgeSub;
  StreamSubscription? _localSub;

  // Responder 侧持有的 Noise session 和 stream
  NoiseSession? _responderSession;
  PeerTunnelStream? _responderStream;
  Uint8List? _responderPeerPublicKey;

  /// 入站配对请求通知（Responder 侧）
  final _incomingRequestController = StreamController<IncomingPairingRequest>.broadcast();
  Stream<IncomingPairingRequest> get incomingPairingRequests => _incomingRequestController.stream;

  // ═══════════════════════════════════════════════════════════════════════
  // Responder 流程（QR 生成方）
  // ═══════════════════════════════════════════════════════════════════════

  /// 开始配对（Responder 侧）
  ///
  /// 同时启动本地 WS Server 和监听 Channel 隧道入站连接。
  /// 返回 QR 码内容字符串（包含内网地址和/或 Channel 端点）。
  Future<String> startPairing() async {
    if (_state != PairingSessionState.idle) {
      await cancelPairing();
    }

    await ensureDeviceInfo();
    // 提前启动 ConnectionManager（确保入站连接 listener 就绪）
    await PeerConnectionManager.instance.start();
    final identity = await NoiseIdentity.loadOrCreate();

    // 生成配对码
    _currentPairingCode = _generatePairingCode();
    _state = PairingSessionState.waitingForScanner;

    // 1. 启动本地 WS Server（内网直连）
    String? localEndpoint;
    try {
      await PeerLocalServer.instance.start();
      localEndpoint = PeerLocalServer.instance.getLocalEndpoint();
      _log.info('Local server started at $localEndpoint', tag: _tag);

      // 监听本地入站连接
      _localSub = PeerLocalServer.instance.incomingConnections.listen(
        _handleIncomingPeerStream,
      );
    } catch (e) {
      _log.warning('Failed to start local server: $e', tag: _tag);
      // 本地服务启动失败不是致命错误，可以仅依赖 Channel
    }

    // 2. 监听 Channel 隧道入站连接（外网穿透）
    String? channelEndpoint;
    try {
      final tunnelConfig = await ChannelTunnelService.instance.loadConfig();
      if (tunnelConfig != null &&
          ChannelTunnelService.instance.currentStatus == TunnelStatus.connected) {
        final endpoint = ChannelTunnelService.instance.getPublicEndpoint(tunnelConfig);
        if (endpoint != null) {
          channelEndpoint = endpoint.replaceFirst('/acp/ws', '/peer/ws');
        }
        _bridgeSub = PeerChannelBridge.instance.incomingConnections.listen(
          _handleIncomingPeerStream,
        );
      }
    } catch (e) {
      _log.warning('Channel tunnel not available: $e', tag: _tag);
    }

    // 至少要有一种连接方式
    if (localEndpoint == null && channelEndpoint == null) {
      _state = PairingSessionState.failed;
      _cleanup();
      throw StateError('无法启动配对：本地服务和 Channel 隧道均不可用');
    }

    // 设置超时
    _timeoutTimer = Timer(_pairingTimeout, () {
      _log.warning('Pairing session timed out', tag: _tag);
      cancelPairing();
    });

    // 生成 QR 码内容
    final qrContent = PeerPairingInfo.encode(
      localEndpoint: localEndpoint,
      channelEndpoint: channelEndpoint,
      code: _currentPairingCode!,
      fingerprint: identity.fingerprintHex,
      publicKey: identity.publicKey,
    );

    _log.info(
      'Pairing started, code=$_currentPairingCode, local=$localEndpoint, channel=$channelEndpoint',
      tag: _tag,
    );
    return qrContent;
  }

  /// 确认配对请求（Responder 侧）
  Future<PairedPeer> confirmPairing(IncomingPairingRequest request) async {
    if (_state != PairingSessionState.receivedRequest) {
      throw StateError('No pending pairing request to confirm');
    }

    // 获取自己的端点信息
    String? myChannelEndpoint;
    try {
      final tunnelConfig = await ChannelTunnelService.instance.loadConfig();
      if (tunnelConfig != null) {
        final endpoint = ChannelTunnelService.instance.getPublicEndpoint(tunnelConfig);
        if (endpoint != null) {
          myChannelEndpoint = endpoint.replaceFirst('/acp/ws', '/peer/ws');
        }
      }
    } catch (_) {}

    final peerId = _uuid.v4();

    // 发送 Noise handshake msg2（PairingResponse）
    final response = PairingResponse(
      accepted: true,
      deviceName: _getDeviceName(),
      deviceId: _getDeviceId(),
      peerId: peerId,
      channelEndpoint: myChannelEndpoint,
      localEndpoint: PeerLocalServer.instance.getLocalEndpoint(),
    );

    final msg2Bytes = await _responderSession!.writeHandshake2(response.toBytes());
    final frame = encodeFrame(Frame(t: FrameType.hs, payload: msg2Bytes));
    _responderStream!.send(Uint8List.fromList(utf8.encode(frame)));

    // 检查是否已配对过（避免重复记录）
    final fingerprint = _fingerprintFromKey(_responderPeerPublicKey!);
    final existingPeer = await _storage.getPeerByFingerprint(fingerprint);

    final peer = PairedPeer(
      id: existingPeer?.id ?? peerId, // 复用已有 ID
      deviceName: request.deviceName,
      deviceId: request.deviceId,
      publicKey: _responderPeerPublicKey!,
      fingerprint: fingerprint,
      channelEndpoint: request.channelEndpoint,
      localEndpoint: request.localEndpoint,
      pairedAt: existingPeer?.pairedAt ?? DateTime.now().millisecondsSinceEpoch,
    );

    await _storage.savePeer(peer); // INSERT OR REPLACE

    _state = PairingSessionState.completed;
    _cleanup();

    // 配对成功后通知 ConnectionManager 建立连接
    PeerConnectionManager.instance.connectToPeer(peer);

    _log.info('Pairing confirmed: ${peer.deviceName} (${peer.fingerprint})', tag: _tag);
    return peer;
  }

  /// 拒绝配对请求（Responder 侧）
  Future<void> rejectPairing(IncomingPairingRequest request) async {
    if (_state != PairingSessionState.receivedRequest) return;

    final response = PairingResponse(
      accepted: false,
      deviceName: _getDeviceName(),
      deviceId: _getDeviceId(),
      peerId: '',
      channelEndpoint: null,
      rejectReason: 'User rejected the pairing request',
    );

    try {
      final msg2Bytes = await _responderSession!.writeHandshake2(response.toBytes());
      final frame = encodeFrame(Frame(t: FrameType.hs, payload: msg2Bytes));
      _responderStream!.send(Uint8List.fromList(utf8.encode(frame)));
    } catch (_) {}

    _state = PairingSessionState.failed;
    _cleanup();
    _log.info('Pairing rejected', tag: _tag);
  }

  /// 取消配对（任意侧）
  Future<void> cancelPairing() async {
    _state = PairingSessionState.cancelled;
    _responderStream?.close();
    _cleanup();
    _log.info('Pairing cancelled', tag: _tag);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Initiator 流程（QR 扫描方）
  // ═══════════════════════════════════════════════════════════════════════

  /// 解析 QR 码内容
  PeerPairingInfo? parsePairingQr(String qrContent) {
    return PeerPairingInfo.tryParse(qrContent);
  }

  /// 发起配对请求（Initiator 侧）
  ///
  /// 优先尝试内网直连，失败后回退到 Channel 穿透。
  /// 成功返回 PairedPeer，失败抛出异常。
  Future<PairedPeer> requestPairing(PeerPairingInfo info) async {
    _state = PairingSessionState.waitingForConfirm;

    await ensureDeviceInfo();
    final identity = await NoiseIdentity.loadOrCreate();

    // 获取自己的 Channel 端点（如果有）
    String? myChannelEndpoint;
    try {
      final tunnelConfig = await ChannelTunnelService.instance.loadConfig();
      if (tunnelConfig != null) {
        final endpoint = ChannelTunnelService.instance.getPublicEndpoint(tunnelConfig);
        if (endpoint != null) {
          myChannelEndpoint = endpoint.replaceFirst('/acp/ws', '/peer/ws');
        }
      }
    } catch (_) {}

    // 尝试连接：优先内网，回退外网
    WebSocketChannel? ws;

    // 1. 优先尝试内网直连
    if (info.localEndpoint != null) {
      try {
        _log.info('Trying local endpoint: ${info.localEndpoint}', tag: _tag);
        final ioSocket = await io.WebSocket.connect(info.localEndpoint!)
            .timeout(const Duration(seconds: 3));
        ws = IOWebSocketChannel(ioSocket);
        _log.info('Connected via local network', tag: _tag);
      } catch (e) {
        _log.debug('Local connection failed: $e, trying channel...', tag: _tag);
      }
    }

    // 2. 回退到 Channel 穿透
    if (ws == null && info.channelEndpoint != null) {
      try {
        _log.info('Trying channel endpoint: ${info.channelEndpoint}', tag: _tag);
        final ioSocket = await io.WebSocket.connect(info.channelEndpoint!)
            .timeout(const Duration(seconds: 10));
        ws = IOWebSocketChannel(ioSocket);
        _log.info('Connected via channel relay', tag: _tag);
      } catch (e) {
        _state = PairingSessionState.failed;
        throw StateError('无法连接到对方设备（内网和外网均失败）: $e');
      }
    }

    if (ws == null) {
      _state = PairingSessionState.failed;
      throw StateError('无可用端点');
    }

    try {
      // 创建 Noise Initiator session
      final session = await NoiseSession.initiator(
        staticPublicKey: identity.publicKey,
        staticPrivateKey: identity.privateKey,
        pinnedPeerStaticPublicKey: info.publicKey,
      );

      // 构造配对请求（包含自己的连接端点，供对方日后连接自己）
      // Initiator 侧获取自己的 localEndpoint（如果本地服务器在运行）
      String? myLocalEndpoint;
      try {
        // 尝试启动本地服务器以提供回连端点
        await PeerLocalServer.instance.start();
        myLocalEndpoint = PeerLocalServer.instance.getLocalEndpoint();
      } catch (_) {}

      final request = PairingRequest(
        pairingCode: info.code,
        deviceName: _getDeviceName(),
        deviceId: _getDeviceId(),
        channelEndpoint: myChannelEndpoint,
        localEndpoint: myLocalEndpoint,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      // 发送 Noise handshake msg1
      final msg1Bytes = await session.writeHandshake1(request.toBytes());
      final frame1 = encodeFrame(Frame(t: FrameType.hs, payload: msg1Bytes));
      ws.sink.add(frame1);

      // 等待 msg2 响应
      final msg2Raw = await ws.stream.first.timeout(
        _pairingTimeout,
        onTimeout: () => throw PairingTimeoutException(),
      );

      final msg2Frame = decodeFrame(msg2Raw as String);
      if (msg2Frame.t != FrameType.hs) {
        throw StateError('Expected handshake frame, got ${msg2Frame.t}');
      }

      // 处理 msg2
      final result = await session.readHandshake2(msg2Frame.payload);
      final response = PairingResponse.fromBytes(result.msg2Payload);

      if (!response.accepted) {
        session.close();
        ws.sink.close();
        _state = PairingSessionState.failed;
        throw PairingRejectedException(response.rejectReason);
      }

      // 配对成功 — 检查是否已配对过
      final existingPeer = await _storage.getPeerByFingerprint(info.fingerprint);

      final peer = PairedPeer(
        id: existingPeer?.id ?? response.peerId, // 复用已有 ID
        deviceName: response.deviceName,
        deviceId: response.deviceId,
        publicKey: info.publicKey,
        fingerprint: info.fingerprint,
        channelEndpoint: response.channelEndpoint,
        localEndpoint: response.localEndpoint ?? info.localEndpoint,
        pairedAt: DateTime.now().millisecondsSinceEpoch,
      );

      await _storage.savePeer(peer);

      _state = PairingSessionState.completed;
      session.close();
      ws.sink.close();

      // 配对成功后通知 ConnectionManager 建立连接
      PeerConnectionManager.instance.connectToPeer(peer);

      _log.info('Pairing successful: ${peer.deviceName} (${peer.fingerprint})', tag: _tag);
      return peer;
    } catch (e) {
      ws.sink.close();
      if (e is PairingRejectedException || e is PairingTimeoutException) rethrow;
      _state = PairingSessionState.failed;
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════════════════

  /// 处理入站 peer stream（Responder 侧，内网或 Channel 均通过此方法）
  void _handleIncomingPeerStream(PeerTunnelStream stream) async {
    if (_state != PairingSessionState.waitingForScanner) {
      // 非配对状态，可能是已配对设备的重连，交给 ConnectionManager
      _log.debug('Incoming peer stream in non-pairing state, stream=${stream.streamId}', tag: _tag);
      return;
    }

    _responderStream = stream;

    try {
      final identity = await NoiseIdentity.loadOrCreate();

      // 创建 Noise Responder session
      _responderSession = await NoiseSession.responder(
        staticPublicKey: identity.publicKey,
        staticPrivateKey: identity.privateKey,
      );

      // 等待 msg1
      final msg1Raw = await stream.incoming.first.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw PairingTimeoutException(),
      );

      // 解码 NoiseEnvelope
      final frame = decodeFrame(utf8.decode(msg1Raw));
      if (frame.t != FrameType.hs) {
        throw StateError('Expected handshake frame, got ${frame.t}');
      }

      // 处理 msg1
      final result = await _responderSession!.readHandshake1(frame.payload);
      _responderPeerPublicKey = result.peerStaticPublicKey;

      // 解析配对请求
      final request = PairingRequest.fromBytes(result.msg1Payload);

      // 验证配对码（常量时间比较）
      if (!_constantTimeEquals(request.pairingCode, _currentPairingCode!)) {
        _log.warning('Pairing code mismatch', tag: _tag);
        final rejectResponse = PairingResponse(
          accepted: false,
          deviceName: _getDeviceName(),
          deviceId: _getDeviceId(),
          peerId: '',
          channelEndpoint: null,
          rejectReason: 'Invalid pairing code',
        );
        final msg2 = await _responderSession!.writeHandshake2(rejectResponse.toBytes());
        final rejectFrame = encodeFrame(Frame(t: FrameType.hs, payload: msg2));
        stream.send(Uint8List.fromList(utf8.encode(rejectFrame)));
        _state = PairingSessionState.failed;
        _cleanup();
        return;
      }

      // 配对码正确，通知 UI 确认
      _state = PairingSessionState.receivedRequest;
      _incomingRequestController.add(IncomingPairingRequest(
        deviceName: request.deviceName,
        deviceId: request.deviceId,
        fingerprint: _fingerprintFromKey(_responderPeerPublicKey!),
        channelEndpoint: request.channelEndpoint,
        localEndpoint: request.localEndpoint,
        streamId: stream.streamId,
      ));

    } catch (e) {
      _log.error('Error handling incoming peer stream', tag: _tag, error: e);
      _state = PairingSessionState.failed;
      _cleanup();
    }
  }

  // ── 工具方法 ────────────────────────────────────────────────────────────

  /// 生成 6 位字母数字配对码（排除易混淆字符 0/O/1/I）
  String _generatePairingCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(_pairingCodeLength, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// 常量时间字符串比较（防止时序攻击）
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  /// 从公钥计算指纹（SHA-256 前 8 字节 hex）
  String _fingerprintFromKey(Uint8List publicKey) {
    final digest = crypto.sha256.convert(publicKey).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 获取本设备名称（优先用户自定义，否则系统 hostname）
  String _getDeviceName() {
    return _cachedDeviceName ?? io.Platform.localHostname;
  }

  /// 获取本设备 UUID（持久化，首次生成后固定）
  String _getDeviceId() {
    return _cachedDeviceId ?? _uuid.v4();
  }

  /// 获取当前设备 ID（公开，供 chat 等模块使用）
  Future<String> getDeviceId() async {
    await ensureDeviceInfo();
    return _cachedDeviceId!;
  }

  // ── 设备信息缓存（在 init 时加载） ────────────────────────────────────

  static const _prefKeyDeviceId = 'peer_device_id';
  static const _prefKeyDeviceName = 'peer_device_name';

  String? _cachedDeviceId;
  String? _cachedDeviceName;

  /// 初始化设备信息（应在使用前调用一次）
  Future<void> ensureDeviceInfo() async {
    if (_cachedDeviceId != null) return;
    final prefs = await SharedPreferences.getInstance();

    // Device ID（固定）
    _cachedDeviceId = prefs.getString(_prefKeyDeviceId);
    if (_cachedDeviceId == null) {
      _cachedDeviceId = _uuid.v4();
      await prefs.setString(_prefKeyDeviceId, _cachedDeviceId!);
    }

    // Device Name（可改）
    _cachedDeviceName = prefs.getString(_prefKeyDeviceName);
    if (_cachedDeviceName == null || _cachedDeviceName!.isEmpty ||
        _cachedDeviceName == 'localhost') {
      // 尝试获取有意义的设备名
      var name = io.Platform.localHostname;
      if (name.isEmpty || name == 'localhost') {
        // 回退：用操作系统 + 部分 deviceId 来区分
        final shortId = _cachedDeviceId!.substring(0, 4).toUpperCase();
        if (io.Platform.isAndroid) {
          name = 'Android-$shortId';
        } else if (io.Platform.isIOS) {
          name = 'iPhone-$shortId';
        } else if (io.Platform.isMacOS) {
          name = 'Mac-$shortId';
        } else if (io.Platform.isWindows) {
          name = 'Windows-$shortId';
        } else if (io.Platform.isLinux) {
          name = 'Linux-$shortId';
        } else {
          name = 'Device-$shortId';
        }
      }
      _cachedDeviceName = name;
      await prefs.setString(_prefKeyDeviceName, _cachedDeviceName!);
    }
  }

  /// 更新本设备名称
  Future<void> setDeviceName(String name) async {
    _cachedDeviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyDeviceName, name);
  }

  /// 获取当前设备名
  Future<String> getDeviceName() async {
    await ensureDeviceInfo();
    return _cachedDeviceName!;
  }

  void _cleanup() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _bridgeSub?.cancel();
    _bridgeSub = null;
    _localSub?.cancel();
    _localSub = null;
    _currentPairingCode = null;
    _responderSession?.close();
    _responderSession = null;
    _responderStream = null;
    _responderPeerPublicKey = null;
    // 注意：不停止 PeerLocalServer，由 PeerConnectionManager 管理其生命周期
  }

  void dispose() {
    _cleanup();
    _incomingRequestController.close();
  }
}
