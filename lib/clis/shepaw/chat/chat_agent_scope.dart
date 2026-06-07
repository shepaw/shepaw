import '../../../services/she_service.dart';

/// 当前执行 chat 命令的 Agent ID（由 ShepawCLI 在每次调用前注入）。
class ChatAgentScope {
  static String agentId = SheService.sheId;
}
