/// Hub `approval.req` / `approval.closed` 在 App 上的状态。
class CommandApprovalInbox {
  final Map<String, CommandApproval> _items = {};

  List<CommandApproval> get items => _items.values.toList();

  void apply(Map<String, dynamic> frame) {
    final type = frame['type'] as String? ?? '';
    final id = frame['approval_id'] as String? ?? '';
    if (id.isEmpty) return;
    if (type == 'approval.req') {
      _items[id] = CommandApproval(
        id: id,
        command: frame['command'] as String? ?? '',
        state: 'pending',
        resolvedBy: null,
      );
      return;
    }
    if (type == 'approval.closed' || type == 'approval.ack') {
      final current = _items[id];
      final resolved = frame['resolved_by'];
      final name = resolved is Map ? resolved['name'] as String? : null;
      _items[id] = CommandApproval(
        id: id,
        command: current?.command ?? frame['command'] as String? ?? '',
        state: frame['state'] as String? ?? 'closed',
        resolvedBy: name,
      );
    }
  }
}

class CommandApproval {
  const CommandApproval({
    required this.id,
    required this.command,
    required this.state,
    required this.resolvedBy,
  });

  final String id;
  final String command;
  final String state;
  final String? resolvedBy;

  bool get pending => state == 'pending';
}
