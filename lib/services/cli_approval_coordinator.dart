import '../clis/shepaw/os/os_executor.dart' as os_exec;

/// Callback used by [CliExecutionGate] when a command needs user confirmation.
typedef CliApprovalHandler = Future<bool> Function(
  String toolName,
  Map<String, dynamic> flags,
  os_exec.RiskLevel risk,
);

/// Last-active chat registers a handler so group / headless turns can reuse
/// the same confirmation UI as DM OS tools.
class CliApprovalCoordinator {
  CliApprovalCoordinator._();
  static final instance = CliApprovalCoordinator._();

  final List<CliApprovalHandler> _handlers = [];

  void register(CliApprovalHandler handler) {
    if (!_handlers.contains(handler)) {
      _handlers.add(handler);
    }
  }

  void unregister(CliApprovalHandler handler) {
    _handlers.remove(handler);
  }

  Future<bool> request(
    String toolName,
    Map<String, dynamic> flags,
    os_exec.RiskLevel risk,
  ) async {
    if (_handlers.isEmpty) return false;
    return _handlers.last(toolName, flags, risk);
  }

  void resetForTest() => _handlers.clear();
}
