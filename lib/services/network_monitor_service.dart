/// 网络环境变化监听服务
///
/// 切换 WiFi / 移动网络 / 断网重连时，旧的隧道与 P2P 连接常变成「半开」失效
/// 连接（TCP 未收到 FIN，状态仍是 connected，但实际收发已不通），需要等很久的
/// 活性超时才会被发现。这里监听连接性变化，在网络稳定后主动：
///   1. 重连 Channel 隧道（让 relay 能重新经本机回推，外网 peer 才连得上）；
///   2. 强制刷新所有 P2P peer 连接（关闭半开旧连接并立即主动重连）。
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'channel_tunnel_service.dart';
import 'logger_service.dart';
import '../peer/services/peer_connection_manager.dart';

class NetworkMonitorService {
  static final NetworkMonitorService _instance = NetworkMonitorService._();
  factory NetworkMonitorService() => _instance;
  NetworkMonitorService._();

  static const _tag = 'NetworkMonitor';
  final _log = LoggerService();

  StreamSubscription<List<ConnectivityResult>>? _sub;
  List<ConnectivityResult>? _last;
  Timer? _debounce;

  /// 开始监听网络变化。可安全多次调用。
  void init() {
    if (_sub != null) return;
    _sub = Connectivity().onConnectivityChanged.listen(
      _onChanged,
      onError: (e) => _log.warning('Connectivity stream error: $e', tag: _tag),
    );
    _log.info('Network monitor started', tag: _tag);
  }

  void _onChanged(List<ConnectivityResult> results) {
    if (_listEquals(results, _last)) return;
    _last = results;

    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    _log.info('Connectivity changed: $results (hasNetwork=$hasNetwork)', tag: _tag);

    // 切网瞬间常先短暂报 none，再切到新网络。无网络时不重连（连了也没用），
    // 等真正有网时再处理。
    if (!hasNetwork) return;

    // 去抖：切换过程会连续触发多次事件，合并为一次重连，避免连接抖动。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _reconnectAll);
  }

  void _reconnectAll() {
    _log.info('Network settled, forcing tunnel + peer reconnect', tag: _tag);
    // 隧道：关闭可能半开的旧 socket，用新网络重建。
    ChannelTunnelService.instance.reconnect();
    // peer：强制刷新所有连接（backgroundedFor > 20s → forceRefresh=true）。
    PeerConnectionManager.instance
        .resumeAll(backgroundedFor: const Duration(minutes: 1));
  }

  bool _listEquals(List<ConnectivityResult>? a, List<ConnectivityResult>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
  }
}
