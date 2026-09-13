/// Peer 本地端点比较 / 学习的纯函数工具。
///
/// 桌面 App 与本机 Nexuspouch 常共享同一局域网 IP、但端口不同。
/// 防自连必须按「本机监听的 host:port」判断，不能 ban 整个本机 IP。
library;

/// 桌面 App 自己的 Peer 口。Hub 避开它，默认用 [kHubPeerDefaultPort]。
const int kAppPeerDefaultPort = 18792;

/// Hub 默认 Peer 端口（与 agent-hub `DEFAULT_PEER_PORT` 对齐）。
const int kHubPeerDefaultPort = 18793;

/// Hub 默认口被占后顺延的扫描上限（含）。再往后几乎只是异常堆积。
const int kHubPeerScanPortEnd = 18799;

/// 把局域网 host 写成 `ws://` 可用的形式（IPv6 加方括号）。
String formatLanWsHost(String host) {
  if (host.contains(':') && !host.startsWith('[')) return '[$host]';
  return host;
}

/// 从 `ws://host:port/path` 取出端口；解析失败返回 null。
int? peerEndpointPort(String? endpoint) {
  if (endpoint == null || endpoint.isEmpty) return null;
  try {
    final uri = Uri.parse(endpoint);
    if (uri.hasPort) return uri.port;
    if (uri.scheme == 'wss' || uri.scheme == 'https') return 443;
    if (uri.scheme == 'ws' || uri.scheme == 'http') return 80;
    return null;
  } catch (_) {
    return null;
  }
}

/// 同一局域网 IP 上 Hub 可能迁到的 Peer URL（已试端口跳过）。
///
/// Hub 默认 18793，被占后 18794…。18792 由 App 先单独试，不放进这里。
List<String> lanPeerScanEndpoints({
  required String lanHost,
  Set<int> skipPorts = const {},
  int startPort = kHubPeerDefaultPort,
  int endPort = kHubPeerScanPortEnd,
  String path = '/peer/ws',
}) {
  if (lanHost.isEmpty || endPort < startPort) return const [];
  final host = formatLanWsHost(lanHost);
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  final urls = <String>[];
  for (var port = startPort; port <= endPort; port++) {
    if (skipPorts.contains(port)) continue;
    urls.add('ws://$host:$port$normalizedPath');
  }
  return urls;
}

/// 判断 [endpoint] 是否指向本机当前 PeerLocalServer 监听地址。
///
/// [ownHost]/[ownPort] 为 `PeerLocalServer.address` / `.port`。
/// 同 IP 不同端口（本机 Nexuspouch）返回 false。
bool isOwnLocalEndpoint(
  String? endpoint, {
  required String? ownHost,
  required int? ownPort,
}) {
  if (endpoint == null || endpoint.isEmpty) return false;
  if (ownHost == null || ownHost.isEmpty || ownPort == null) return false;
  try {
    final uri = Uri.parse(endpoint);
    final host = uri.host;
    if (host.isEmpty) return false;
    final port = uri.hasPort ? uri.port : 80;
    if (port != ownPort) return false;
    if (host == ownHost) return true;
    // 本机 loopback 打到自己的监听端口也算自连
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// 根据入站 TCP 来源 IP 推导应写入的 localEndpoint。
///
/// - 已有 endpoint：只刷新 host，保留 port / path（避免把 Nexuspouch 端口盖成 18792）
/// - 无 endpoint：退回 `ws://ip:defaultPort/peer/ws`
/// - 结果若等于本机监听端点则返回 null（不学习）
String? learnLocalEndpointFromRemoteAddress({
  required String remoteAddress,
  String? existingLocalEndpoint,
  required int defaultPort,
  String? ownHost,
  int? ownPort,
}) {
  if (remoteAddress.isEmpty) return null;

  final host =
      remoteAddress.contains(':') && !remoteAddress.startsWith('[')
          ? '[$remoteAddress]'
          : remoteAddress;

  String candidate;
  final existing = existingLocalEndpoint;
  if (existing != null && existing.isNotEmpty) {
    try {
      final uri = Uri.parse(existing);
      final port = uri.hasPort ? uri.port : defaultPort;
      final path = uri.path.isEmpty ? '/peer/ws' : uri.path;
      candidate = 'ws://$host:$port$path';
    } catch (_) {
      candidate = 'ws://$host:$defaultPort/peer/ws';
    }
  } else {
    candidate = 'ws://$host:$defaultPort/peer/ws';
  }

  if (isOwnLocalEndpoint(candidate, ownHost: ownHost, ownPort: ownPort)) {
    return null;
  }
  if (candidate == existingLocalEndpoint) return null;
  return candidate;
}
