import '../acp_agent_connection.dart';

/// 判定一个连接层异常是否值得重试。
///
/// 不重试（身份/授权/配置类错误，重试无意义，立即 rethrow 交给用户）：
///   - [FingerprintMismatchException]：Agent 身份指纹变了，需重新配对
///   - [FingerprintMissingException]：缺少已固定指纹，需重新配对
///   - [AgentIdMismatchException]：目标 agentId 不匹配
///   - [PeerNotAuthorizedException]：本设备不在 Agent 白名单
///   - [PeerUnregisteredException]：本设备被 Agent 移除白名单
///   - 错误消息含 `401/unauthorized/403/forbidden`：鉴权失败
///
/// 重试（瞬时网络/服务未就绪等，首次失败后再试一次通常能成）：
///   - `TimeoutException` / `SocketException` / `WebSocketException`
///   - [NoiseHandshakeError]：握手泛错（可能为丢包/半关）
///   - 错误消息含 `502/503/not upgraded/ServiceUnavailable`：隧道未就绪
///   - 其余一切未分类错误（保守默认：重试）
bool isRetriableConnectionError(Object e) {
  if (e is FingerprintMismatchException) return false;
  if (e is FingerprintMissingException) return false;
  if (e is AgentIdMismatchException) return false;
  if (e is PeerNotAuthorizedException) return false;
  if (e is PeerUnregisteredException) return false;

  final s = e.toString().toLowerCase();
  if (s.contains('401') ||
      s.contains('unauthorized') ||
      s.contains('403') ||
      s.contains('forbidden')) {
    return false;
  }

  return true;
}

/// 指数退避间隔：500ms → 1s → 2s（总计约 3.5s）。
/// 数组长度等于 [kReconnectMaxAttempts] - 1（最后一次失败不再等待）。
const List<Duration> kReconnectBackoffs = [
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// 主动重连最大尝试次数。
const int kReconnectMaxAttempts = 3;
