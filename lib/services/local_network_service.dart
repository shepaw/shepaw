/// 本地网络服务
/// 提供获取本机局域网 IP 地址的功能
library;

import 'dart:io';

/// 本地网络服务
class LocalNetworkService {
  /// VPN / 隧道接口名前缀，需要排除
  static const _tunnelPrefixes = [
    'utun',  // macOS VPN 隧道（Wireguard、IPSec 等）
    'tun',   // Linux/Android VPN
    'tap',   // TAP 虚拟网卡
    'ppp',   // PPP 拨号/VPN
    'ipsec',
    'gif',   // macOS 通用隧道接口
    'stf',   // 6to4 隧道
  ];

  /// 判断接口名是否属于 VPN/隧道接口
  static bool _isTunnelInterface(String name) {
    final lower = name.toLowerCase();
    return _tunnelPrefixes.any((prefix) => lower.startsWith(prefix));
  }

  /// 获取所有局域网 IPv4 地址（排除 loopback、link-local、VPN/隧道接口）
  static Future<List<String>> getLocalIPs() async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        // 跳过 VPN / 隧道接口（如 utun4、tun0 等）
        if (_isTunnelInterface(interface.name)) continue;

        for (final address in interface.addresses) {
          final ip = address.address;
          // 排除 loopback（127.x.x.x）和 link-local（169.254.x.x）
          if (!address.isLoopback && !ip.startsWith('169.254.')) {
            result.add(ip);
          }
        }
      }
    } catch (_) {
      // 获取失败时返回空列表
    }
    return result;
  }

  /// 获取首选局域网 IP（优先 192.168.x.x / 10.x.x.x / 172.16-31.x.x）
  static Future<String?> getPreferredLocalIP() async {
    final ips = await getLocalIPs();
    if (ips.isEmpty) return null;

    for (final ip in ips) {
      if (ip.startsWith('192.168.') ||
          ip.startsWith('10.') ||
          _is172Private(ip)) {
        return ip;
      }
    }
    return ips.first;
  }

  /// 构建本地 ACP Server 的 WebSocket 连接地址列表
  static Future<List<String>> getACPServerAddresses({int port = 18790}) async {
    final ips = await getLocalIPs();
    return ips.map((ip) => 'ws://$ip:$port/acp/ws').toList();
  }

  /// 判断 172.x.x.x 是否属于私有网段（172.16.0.0 - 172.31.255.255）
  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }
}
