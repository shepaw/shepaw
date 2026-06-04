/// Channel 隧道与 P2P 连接的桥接层
///
/// 负责：
/// 1. 接收来自 Channel 隧道的 /peer/ws 连接请求
/// 2. 为每个入站连接建立双向数据流
/// 3. 将数据流交给 PeerConnectionManager 处理
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../services/logger_service.dart';

/// 表示一个通过 Channel 隧道建立的 peer WebSocket 连接
/// 封装了隧道消息的收发逻辑
class PeerTunnelStream {
  /// 隧道流 ID（Channel 服务分配）
  final int streamId;

  /// 接收来自远端 peer 的数据
  final Stream<Uint8List> incoming;

  /// 发送数据到远端 peer
  final void Function(Uint8List data) send;

  /// 关闭连接
  final void Function() close;

  /// 远端在本地网络中的地址（仅本地直连入站时已知；Channel 中继入站为 null）。
  /// 用于学习对端当前内网 IP，使存储的 localEndpoint 在换网后自愈。
  final String? remoteAddress;

  /// 连接是否已关闭
  bool _closed = false;
  bool get isClosed => _closed;

  PeerTunnelStream({
    required this.streamId,
    required this.incoming,
    required this.send,
    required this.close,
    this.remoteAddress,
  });

  void markClosed() => _closed = true;
}

/// Channel 隧道的 P2P 桥接服务（单例）
///
/// 当 ChannelTunnelService 收到 /peer/ws 的 ws_connect 请求时，
/// 通过此服务创建 PeerTunnelStream 并通知 PeerConnectionManager。
class PeerChannelBridge {
  PeerChannelBridge._();
  static final PeerChannelBridge instance = PeerChannelBridge._();

  static const _tag = 'PeerChannelBridge';
  final _log = LoggerService();

  /// 新的入站 peer 连接流
  final _incomingController = StreamController<PeerTunnelStream>.broadcast();
  Stream<PeerTunnelStream> get incomingConnections => _incomingController.stream;

  /// 发送隧道消息的回调（由 ChannelTunnelService 注入）
  void Function(Map<String, dynamic> msg)? _sendTunnelMessage;

  /// 活跃的 peer stream（stream_id → controller）
  final Map<int, StreamController<Uint8List>> _activeStreams = {};

  /// 注入隧道消息发送能力
  void bindTunnelSender(void Function(Map<String, dynamic> msg) sender) {
    _sendTunnelMessage = sender;
    _log.debug('Tunnel sender bound', tag: _tag);
  }

  /// 解除绑定（隧道断开时）
  void unbindTunnelSender() {
    _sendTunnelMessage = null;
    // 关闭所有活跃 stream
    for (final ctrl in _activeStreams.values) {
      if (!ctrl.isClosed) ctrl.close();
    }
    _activeStreams.clear();
    _log.debug('Tunnel sender unbound, all streams closed', tag: _tag);
  }

  /// 处理来自 Channel 隧道的 ws_connect 请求（/peer/ws 路径）
  /// 由 ChannelTunnelService._forwardWsConnect 调用
  void handlePeerWsConnect(int streamId) {
    _log.info('Incoming peer connection, stream=$streamId', tag: _tag);

    final dataCtrl = StreamController<Uint8List>();
    _activeStreams[streamId] = dataCtrl;

    final stream = PeerTunnelStream(
      streamId: streamId,
      incoming: dataCtrl.stream,
      send: (data) => _sendWsData(streamId, data),
      close: () => _closePeerStream(streamId),
    );

    _incomingController.add(stream);
  }

  /// 处理来自 Channel 隧道的 ws_data 消息（peer 流）
  void handlePeerWsData(int streamId, Uint8List data) {
    final ctrl = _activeStreams[streamId];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(data);
    }
  }

  /// 处理来自 Channel 隧道的 ws_close 消息（peer 流）
  void handlePeerWsClose(int streamId) {
    final ctrl = _activeStreams.remove(streamId);
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.close();
    }
    _log.debug('Peer stream closed, stream=$streamId', tag: _tag);
  }

  /// 主动连接对方的 Channel 端点
  /// 通过 Channel 服务的代理路径连接到对方设备
  /// 返回一个 PeerTunnelStream 供 Initiator 使用
  ///
  /// 注意：这需要通过 HTTP/WS 客户端直接连接对方的公开 Channel URL，
  /// 而非通过自己的隧道。因此这里不走 tunnel 转发，而是直接建立 WebSocket。
  // 该功能在 PeerPairingService 中实现（直接 WebSocket 连接对方 Channel URL）

  // ── 内部方法 ───────────────────────────────────────────────────────────

  void _sendWsData(int streamId, Uint8List data) {
    final sender = _sendTunnelMessage;
    if (sender == null) {
      _log.warning('Cannot send ws_data: tunnel not connected', tag: _tag);
      return;
    }
    sender({
      'type': 'ws_data',
      'stream_id': streamId,
      'body': base64Encode(data),
      'ws_msg_type': 2, // binary
    });
  }

  void _closePeerStream(int streamId) {
    final ctrl = _activeStreams.remove(streamId);
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.close();
    }
    final sender = _sendTunnelMessage;
    if (sender != null) {
      sender({
        'type': 'ws_close',
        'stream_id': streamId,
      });
    }
  }

  void dispose() {
    unbindTunnelSender();
    _incomingController.close();
  }
}
