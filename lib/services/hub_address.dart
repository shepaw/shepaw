/// 远端 Agent Hub 地址的解析与判定（纯函数，零 IO）。
///
/// 只做两件事：把用户手输的地址归一化成可用的 dashboard URI，
/// 以及判断一个 host 是不是内网 / 回环（决定要不要提示 token 会明文传输）。
library;

/// `shepaw-hub web` 的默认仪表盘端口。
const int kAgentHubDashboardPort = 4000;

/// 把用户输入的 Hub 地址归一化成 dashboard 根 URI；无法解析时返回 `null`。
///
/// 接受（未写 scheme 时按 `http` 处理，未写端口时补 [defaultPort]）：
/// - `192.168.1.5`
/// - `192.168.1.5:4000`
/// - `http://192.168.1.5:4000/`
/// - `[fe80::1]:4000`
///
/// 拒绝：空串、非 http(s) scheme、host 为空、带 userInfo、端口越界。
///
/// path / query / fragment 一律丢弃 —— 配对固定打 `/api/*`，
/// 用户从浏览器地址栏复制的 `http://host:4000/#/instances` 也要能用。
///
/// ⚠️ 显式写了 `https://` 且没写端口时**不补** [defaultPort]：https 通常挂在
/// 反向代理后面，硬补 4000 只会打到一个不开 TLS 的端口。
Uri? normalizeHubDashboardUrl(
  String raw, {
  int defaultPort = kAgentHubDashboardPort,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // ⚠️ 必须用 `contains('://')` 判断有没有 scheme，**不能**用 `uri.hasScheme`：
  // `Uri.parse('192.168.1.5:4000')` 会把 `192.168.1.5` 当成 scheme
  // （`hasScheme == true`、`host == ''`、`hasPort == false`），
  // 于是裸 `host:port` 这种最常见的输入会被判成非法。
  final Uri parsed;
  final bool hadScheme = trimmed.contains('://');
  try {
    parsed = Uri.parse(hadScheme ? trimmed : 'http://$trimmed');
  } on FormatException {
    return null;
  }

  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (parsed.host.isEmpty) return null;
  if (parsed.userInfo.isNotEmpty) return null;

  if (parsed.hasPort) {
    final port = parsed.port;
    if (port <= 0 || port > 65535) return null;
    return Uri(scheme: scheme, host: parsed.host, port: port);
  }

  // https 交给反向代理，不补默认端口。
  if (scheme == 'https') {
    return Uri(scheme: scheme, host: parsed.host);
  }
  if (defaultPort <= 0 || defaultPort > 65535) return null;
  return Uri(scheme: scheme, host: parsed.host, port: defaultPort);
}

/// 该 host 是否属于内网 / 回环（含 IPv4 私有段、link-local 与 IPv6 回环 / ULA）。
///
/// 用于决定要不要提示「token 会以明文发送」。域名一律判为**公网** ——
/// 拿不到 DNS 解析结果，宁可多提示一次也不要漏报。
bool isPrivateOrLoopback(String host) {
  var h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (h == 'localhost' || h == '::1') return true;

  // IPv6 链接本地（fe80::/10）与唯一本地地址（fc00::/7）。
  if (h.contains(':')) {
    return h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd');
  }

  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }

  final a = octets[0];
  final b = octets[1];
  if (a == 127 || a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  // APIPA / link-local：拿到这个地址说明根本没连上路由器。
  if (a == 169 && b == 254) return true;
  return false;
}

/// 该地址是否需要提示「令牌会明文传输」：公网 IP / 域名 + 明文 http。
bool isInsecureDashboard(Uri dashboardUri) {
  return dashboardUri.scheme == 'http' &&
      !isPrivateOrLoopback(dashboardUri.host);
}
