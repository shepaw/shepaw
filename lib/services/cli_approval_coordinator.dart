import '../clis/shepaw/os/os_executor.dart' as os_exec;

/// Callback used by [CliExecutionGate] when a command needs user confirmation.
typedef CliApprovalHandler = Future<bool> Function(
  String toolName,
  Map<String, dynamic> flags,
  os_exec.RiskLevel risk,
);

/// Last-active chat registers a handler so group / headless turns can reuse
/// the same confirmation UI as DM OS tools.
///
/// [grantForSession] remembers a command until process exit (or
/// [resetForTest]) so frequent low-risk CLIs are not re-prompted every call.
class CliApprovalCoordinator {
  CliApprovalCoordinator._();
  static final instance = CliApprovalCoordinator._();

  final List<CliApprovalHandler> _handlers = [];
  final Set<String> _sessionGrants = {};

  void register(CliApprovalHandler handler) {
    if (!_handlers.contains(handler)) {
      _handlers.add(handler);
    }
  }

  void unregister(CliApprovalHandler handler) {
    _handlers.remove(handler);
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
    os_exec.RiskLevel risk,
  ) async {
    if (isGrantedForSession(toolName)) return true;
    if (_handlers.isEmpty) return false;
    return _handlers.last(toolName, flags, risk);
  }

  void resetForTest() {
    _handlers.clear();
    _sessionGrants.clear();
  }
}
