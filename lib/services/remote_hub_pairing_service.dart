import 'package:http/http.dart' as http;

import '../peer/models/pairing_payload.dart';
import 'hub_api_client.dart';
import 'local_agent_hub_host.dart';
import 'local_agent_hub_models.dart';

/// 远端 Hub 取码失败。[code] 供 UI 选文案，与 [LocalHubException] 同一套路。
class RemoteHubException implements Exception {
  RemoteHubException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// 从远端 Hub 取到的配对票据（**尚未配对**）。
class RemoteHubTicket {
  const RemoteHubTicket({
    required this.info,
    required this.fingerprint,
    required this.dashboardUri,
  });

  /// 已解析的配对信息；`local` 端点已按本机网卡重写过。
  final PeerPairingInfo info;

  /// Hub 自报的指纹。取票据时已校验其等于 [PeerPairingInfo.fingerprint]。
  final String fingerprint;

  final Uri dashboardUri;
}

/// 向**另一台设备**上的 Agent Hub 要一个配对码。
///
/// 刻意不复用 [LocalAgentHubService]：那个类的 `detect()` / `installAndJoin()` /
/// snooze prefs 全是「本机」专属概念，混进远端路径会让它变成两种东西。
///
/// 也刻意**只取码、不配对** —— Agent Hub 的 peer 服务握手时只校验配对码，
/// 不校验是谁（`agent-hub/core/src/peer/peer-server.ts`），所以「谁能访问到
/// 对方 Hub 的仪表盘 API，谁就能把自己配上去」。确认闸门必须留在 UI 上，
/// 让用户先看清 Hub 地址与指纹。
class RemoteHubPairingService {
  RemoteHubPairingService({
    http.Client? httpClient,
    Future<Set<String>> Function()? localIpv4s,
    this.healthTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 15),
  })  : _http = httpClient,
        _localIpv4s =
            localIpv4s ?? LocalAgentHubHost.platform().localIpv4s;

  final http.Client? _http;
  final Future<Set<String>> Function() _localIpv4s;
  final Duration healthTimeout;
  final Duration requestTimeout;

  /// 探测 → `/api/peer/start` → `/api/peer/pair`，返回可展示给用户确认的票据。
  ///
  /// 失败一律抛 [RemoteHubException]，[RemoteHubException.code] 见下表：
  /// `unreachable` / `not-hub` / `auth-required` / `unauthorized` /
  /// `start-failed` / `pair-failed` / `bad-response` / `bad-qr` /
  /// `fingerprint-mismatch`。
  Future<RemoteHubTicket> mintTicket(Uri dashboardUri, {String? token}) async {
    final trimmedToken = token?.trim();
    final client = HubApiClient(
      dashboardUri: dashboardUri,
      token: (trimmedToken == null || trimmedToken.isEmpty) ? null : trimmedToken,
      httpClient: _http,
      healthTimeout: healthTimeout,
      requestTimeout: requestTimeout,
    );

    final probe = await client.health();
    switch (probe.status) {
      case HubProbeStatus.unreachable:
        throw RemoteHubException(
          'Agent Hub dashboard is unreachable at $dashboardUri',
          code: 'unreachable',
        );
      case HubProbeStatus.notHub:
        throw RemoteHubException(
          'No Agent Hub dashboard responded at $dashboardUri',
          code: 'not-hub',
        );
      case HubProbeStatus.ok:
        break;
    }
    if (probe.authRequired && client.token == null) {
      throw RemoteHubException(
        'Dashboard requires SHEPAW_HUB_TOKEN',
        code: 'auth-required',
      );
    }

    // 顺序不能反：pair 之前必须先 start，否则 Hub 侧没有待配对的会话。
    await _post(client, '/api/peer/start', failureCode: 'start-failed');

    final ticketJson =
        await _post(client, '/api/peer/pair', failureCode: 'pair-failed');
    final ticket = parsePairTicket(ticketJson);
    if (ticket == null) {
      throw RemoteHubException(
        'Hub pairing response missing QR payload',
        code: 'bad-response',
      );
    }

    final info = PeerPairingInfo.tryParse(ticket.qrPayload);
    if (info == null) {
      throw RemoteHubException('Hub pairing QR is invalid', code: 'bad-qr');
    }

    // 免费的一致性证明：ticket.fingerprint 是 Hub 自报的，info.fingerprint 是
    // 从 QR 里的公钥重算出来的。两者不等说明响应串包 / 被人换过。
    if (info.fingerprint.toLowerCase() != ticket.fingerprint.toLowerCase()) {
      throw RemoteHubException(
        'Hub fingerprint ${ticket.fingerprint} does not match QR '
        '${info.fingerprint}',
        code: 'fingerprint-mismatch',
      );
    }

    return RemoteHubTicket(
      info: await _rewriteLocalEndpoint(info),
      fingerprint: ticket.fingerprint,
      dashboardUri: dashboardUri,
    );
  }

  Future<Object> _post(
    HubApiClient client,
    String path, {
    required String failureCode,
  }) async {
    try {
      return await client.postJson(path);
    } on HubApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        throw RemoteHubException(
          'Hub rejected the token for $path (HTTP ${e.statusCode})',
          code: 'unauthorized',
        );
      }
      throw RemoteHubException(
        'Hub $path failed HTTP ${e.statusCode}: ${e.body}',
        code: failureCode,
      );
    } catch (e) {
      // 连接被拒 / 超时 / DNS 失败：探测时还活着，这会儿掉线了。
      throw RemoteHubException('Hub $path failed: $e', code: 'unreachable');
    }
  }

  /// 把指向**本机**的内网端点重写成回环地址。
  ///
  /// 场景：用户在手机 / 另一台机器上填了这台电脑的 LAN IP —— 对本机而言
  /// 走 `127.0.0.1` 可以绕开防火墙，而防火墙往往只放行了仪表盘的 4000，
  /// 没放行 peer 服务的 18793。
  Future<PeerPairingInfo> _rewriteLocalEndpoint(PeerPairingInfo info) async {
    final local = info.localEndpoint;
    if (local == null) return info;
    Set<String> locals;
    try {
      locals = await _localIpv4s();
    } catch (_) {
      locals = const {'127.0.0.1'};
    }
    return info.copyWith(localEndpoint: preferLoopbackIfLocal(local, locals));
  }
}
