/// 本地 WebSocket Server — 用于内网 P2P 直连
///
/// 在同一局域网内，QR 生成方启动本地 WS Server 监听连接，
/// 扫描方直接通过内网 IP 连接，无需经过 Channel 服务。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../services/logger_service.dart';
import 'peer_channel_bridge.dart';

/// 本地 P2P WebSocket 服务器
class PeerLocalServer {
  PeerLocalServer._();
  static final PeerLocalServer instance = PeerLocalServer._();

  static const _tag = 'PeerLocalServer';
  final _log = LoggerService();

  HttpServer? _server;
  bool _running = false;

  /// 新的入站连接流（与 PeerChannelBridge 相同的 PeerTunnelStream 接口）
  final _incomingController = StreamController<PeerTunnelStream>.broadcast();
  Stream<PeerTunnelStream> get incomingConnections => _incomingController.stream;

  /// 当前监听端口
  int? get port => _server?.port;

  /// 当前监听地址
  String? get address => _server != null ? _localIp : null;

  /// 是否正在运行
  bool get isRunning => _running;

  String? _localIp;
  int _streamIdCounter = 100000; // 避免与 Channel tunnel stream IDs 冲突

  /// P2P 连接使用的固定端口
  static const int defaultPort = 18792;

  /// 启动服务器
  ///
  /// 使用固定端口（默认 18791），确保重启后端口不变。
  /// 返回实际监听的端口号。
  Future<int> start({int? port}) async {
    if (_running) return _server!.port;

    final usePort = port ?? defaultPort;
    _localIp = await getLocalIp();
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, usePort);
    } catch (e) {
      // 固定端口被占用时回退到随机端口
      _log.warning('Port $usePort in use, using random port', tag: _tag);
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _running = true;

    _log.info('Local P2P server started on $_localIp:${_server!.port}', tag: _tag);

    // 处理 HTTP 请求
    _server!.listen((request) {
      if (request.uri.path == '/peer/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        _handleWebSocketUpgrade(request);
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found')
          ..close();
      }
    });

    return _server!.port;
  }

  /// 停止服务器
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _server?.close(force: true);
    _server = null;
    _log.info('Local P2P server stopped', tag: _tag);
  }

  /// 获取本地 WebSocket 端点 URL
  String? getLocalEndpoint() {
    if (!_running || _localIp == null) return null;
    return 'ws://$_localIp:${_server!.port}/peer/ws';
  }

  /// 获取本机局域网 IP 地址
  static Future<String> getLocalIp() async {
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // ── 内部方法 ────────────────────────────────────────────────────────────

  void _handleWebSocketUpgrade(HttpRequest request) async {
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      final streamId = _streamIdCounter++;

      _log.info(
        'Incoming local WS connection from ${request.connectionInfo?.remoteAddress.address}, stream=$streamId',
        tag: _tag,
      );

      final dataCtrl = StreamController<Uint8List>();

      // 监听来自 WebSocket 的数据
      ws.listen(
        (data) {
          if (data is String) {
            dataCtrl.add(Uint8List.fromList(utf8.encode(data)));
          } else if (data is List<int>) {
            dataCtrl.add(Uint8List.fromList(data));
          }
        },
        onDone: () {
          if (!dataCtrl.isClosed) dataCtrl.close();
        },
        onError: (_) {
          if (!dataCtrl.isClosed) dataCtrl.close();
        },
      );

      final stream = PeerTunnelStream(
        streamId: streamId,
        incoming: dataCtrl.stream,
        send: (data) {
          if (ws.readyState == WebSocket.open) {
            // 发送为 text frame（NoiseEnvelope 是 JSON 字符串）
            ws.add(utf8.decode(data));
          }
        },
        close: () {
          ws.close();
          if (!dataCtrl.isClosed) dataCtrl.close();
        },
      );

      _incomingController.add(stream);
    } catch (e) {
      _log.error('WebSocket upgrade failed', tag: _tag, error: e);
    }
  }

  void dispose() {
    stop();
    _incomingController.close();
  }
}
