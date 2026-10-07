import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/device_node/command_approval_inbox.dart';

void main() {
  test('a closed frame freezes the pending card', () {
    final inbox = CommandApprovalInbox();
    inbox.apply({
      'type': 'approval.req',
      'approval_id': 'ap_1',
      'command': 'os.command.exec',
    });
    expect(inbox.items.single.pending, isTrue);
    inbox.apply({
      'type': 'approval.closed',
      'approval_id': 'ap_1',
      'state': 'approved',
      'resolved_by': {'device_id': 'dev_phone', 'name': 'Eden 的 iPhone'},
    });
    expect(inbox.items.single.pending, isFalse);
    expect(inbox.items.single.state, 'approved');
    expect(inbox.items.single.resolvedBy, 'Eden 的 iPhone');
  });
}
