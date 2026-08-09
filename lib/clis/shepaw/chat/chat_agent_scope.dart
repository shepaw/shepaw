import '../../../services/she_service.dart';

/// 当前 CLI 执行上下文（由 [ShepawCLI.execute] 在每次调用前注入）。
///
/// 供 `store write` 等命令解析 runtime 落点：
/// `runtime/<agentOrGroup>/<channel>/artifacts/...`
class ChatAgentScope {
  static String agentId = SheService.sheId;

  /// 当前对话频道；空字符串表示未知。
  static String channelId = '';
}
