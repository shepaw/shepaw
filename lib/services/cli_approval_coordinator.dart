import '../clis/shepaw/os/os_executor.dart' as os_exec;
import 'approval/cli_approval_card.dart';
import 'logger_service.dart';

/// Callback used by [CliExecutionGate] when a command needs user confirmation.
///
/// [channelId] / [agentId] 是**发起回合**的归属，不是"当前可见"的会话。
/// 必填 —— 漏传就是编译错误，不允许退回当前会话兜底。
typedef CliApprovalHandler = Future<bool> Function(
  String toolName,
  Map<String, dynamic> flags,
  os_exec.RiskLevel risk, {
  required String? channelId,
  required String? agentId,
});

/// Routes CLI / OS approvals to the chat page that **owns** the turn.
///
/// 每个 ChatController 按自己当前频道登记；请求按 [channelId] 分发。归属频道
/// 没有页面在显示时，卡片落库到那个频道 + 顶部横幅提醒，绝不落到当前页面。
///
/// [grantForSession] remembers a command until process exit (or
/// [resetForTest]) so frequent low-risk CLIs are not re-prompted every call.
class CliApprovalCoordinator {
  CliApprovalCoordinator._();
  static final instance = CliApprovalCoordinator._();

  static const _tag = 'CliApproval';

  final Map<String, CliApprovalHandler> _handlers = {};
  final Set<String> _sessionGrants = {};

  /// 登记 [channelId] 的审批处理者。
  ///
  /// 一个 handler 只属于一个频道：换频道时旧的登记先撤掉，否则旧频道的审批
  /// 会打到已经显示别的频道的 controller 上。
  void register(
    CliApprovalHandler handler, {
    required String? channelId,
  }) {
    unregister(handler);
    final key = channelId?.trim() ?? '';
    if (key.isEmpty) return;
    _handlers[key] = handler;
  }

  void unregister(CliApprovalHandler handler) {
    _handlers.removeWhere((_, h) => h == handler);
  }

  bool isGrantedForSession(String toolName) =>
      _sessionGrants.contains(toolName);

  void grantForSession(String toolName) {
    final id = toolName.trim();
    if (id.isNotEmpty) _sessionGrants.add(id);
  }

  Future<bool> request(
    String toolName,
    Map<String, dynamic> flags,
    os_exec.RiskLevel risk, {
    required String? channelId,
    required String? agentId,
  }) async {
    if (isGrantedForSession(toolName)) return true;

    final owner = channelId?.trim() ?? '';
    if (owner.isEmpty) {
      // 没有归属会话 = 调用链漏了 channelId，属于 bug。宁可拒绝也不把卡
      // 扔进用户正在看的会话里。
      LoggerService().warning(
        'CLI approval for $toolName has no owning channel — denied '
        '(an approval card must belong to a channel)',
        tag: _tag,
      );
      return false;
    }

    final handler = _handlers[owner];
    if (handler == null) {
      // 归属频道的页面没开着：卡落进那个频道 + 顶部提醒，等用户跳回去点。
      return CliApprovalCard.awaitOffscreen(
        confirmationId: CliApprovalCard.confirmationIdFor(toolName),
        toolName: toolName,
        flags: flags,
        risk: risk,
        channelId: owner,
        agentId: agentId?.trim() ?? '',
      );
    }
    return handler(
      toolName,
      flags,
      risk,
      channelId: owner,
      agentId: agentId,
    );
  }

  void resetForTest() {
    _handlers.clear();
    _sessionGrants.clear();
  }
}
