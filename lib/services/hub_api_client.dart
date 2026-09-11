import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_agent_hub_models.dart';

/// 探测结果。刻意把「连不上」和「有响应但不是 Hub」分开 ——
/// 两者的排障方向完全不同（查网络 vs 查地址填错），文案合并会把人带偏。
enum HubProbeStatus {
  /// `/api/health` 返回 200 且 body 是 `{"ok":true,...}`。
  ok,

  /// 完全没有拿到 HTTP 响应：连接被拒 / 超时 / DNS 失败 / TLS 握手失败。
  unreachable,

  /// 拿到了 HTTP 响应，但它不是 Agent Hub 仪表盘（404、非 JSON、`{"ok":false}`…）。
  notHub,
}

class HubProbeResult {
  const HubProbeResult(this.status, {this.authRequired = false});

  final HubProbeStatus status;

  /// 仅当 [status] 为 [HubProbeStatus.ok] 时有意义。
  final bool authRequired;

  bool get isOk => status == HubProbeStatus.ok;
}

/// Hub 返回了非 2xx。网络层错误（超时 / 连接被拒）不走这里，原样抛出。
class HubApiException implements Exception {
  HubApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'HubApiException(HTTP $statusCode): $body';
}

/// 可指向任意 Agent Hub 仪表盘地址的 HTTP 客户端。
///
/// 与 [LocalAgentHubService] 的区别只有一个：dashboard 地址是入参，
/// 所以既能打本机 `127.0.0.1:4000`，也能打局域网里另一台机器的 Hub。
class HubApiClient {
  HubApiClient({
    required this.dashboardUri,
    this.token,
    http.Client? httpClient,
    // 本机是回环，2s 足够；跨网段要给够，否则一次抖动就被判成「连不上」。
    this.healthTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client();

  final Uri dashboardUri;

  /// `SHEPAW_HUB_TOKEN`。为 null 时不发 `Authorization` 头。
  final String? token;
  final Duration healthTimeout;
  final Duration requestTimeout;

  final http.Client _http;

  /// 探测 `/api/health`。**不抛异常** —— 所有失败都归类进 [HubProbeResult]。
  Future<HubProbeResult> health() async {
    final http.Response resp;
    try {
      resp = await _http
          .get(dashboardUri.replace(path: '/api/health'), headers: _headers)
          .timeout(healthTimeout);
    } catch (_) {
      return const HubProbeResult(HubProbeStatus.unreachable);
    }
    // 只有「200 且自报 ok」才算 Hub。鉴权失败（理论不该发生，health 免鉴权）
    // 与 404 一视同仁地归为 not-hub：都说明这个地址不是我们要找的东西。
    if (resp.statusCode != 200 || !parseDashboardHealthOk(resp.body)) {
      return const HubProbeResult(HubProbeStatus.notHub);
    }
    return HubProbeResult(
      HubProbeStatus.ok,
      authRequired: parseDashboardAuthRequired(resp.body),
    );
  }

  /// POST 一个空 JSON body 到 [path]（如 `/api/peer/start`）。
  ///
  /// 非 2xx 抛 [HubApiException]；连不上 / 超时原样抛底层异常，
  /// 由调用方决定怎么归类。
  Future<Object> postJson(String path) async {
    final resp = await _http
        .post(
          dashboardUri.replace(path: path),
          headers: {..._headers, 'content-type': 'application/json'},
          body: '{}',
        )
        .timeout(requestTimeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HubApiException(resp.statusCode, resp.body);
    }
    if (resp.body.isEmpty) return const <String, dynamic>{};
    return jsonDecode(resp.body);
  }

  Map<String, String> get _headers => token == null || token!.isEmpty
      ? const {}
      : {'authorization': 'Bearer $token'};
}
