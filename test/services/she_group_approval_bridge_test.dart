import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/group_interaction_planner.dart';
import 'package:shepaw/services/group/she_group_approval_bridge.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  test('bridge metadata key is stable for UI rendering', () {
    expect(SheGroupApprovalBridge.bridgeMetaKey, 'group_approval_bridge');
  });

  test('She DM group management playbook mentions group send', () {
    final block = SheService.buildDmGroupManagementPlaybookBlock();
    expect(block, contains('chat group send'));
    expect(block, contains('She-bound group session'));
  });

  test('peer action_confirmation without saved id needs dedicated host', () {
    // Mirrors SheGroupApprovalBridge policy: peer approvals without an
    // explicit _savedMessageId must not latch onto a stale prior bubble.
    expect(
      GroupInteractionPlanner.needsPeerApprovalFallback(
        preferredSid: null,
        preferredExists: false,
        interactionType: 'action_confirmation',
        data: {'confirmation_context': 'peer'},
        hasChannel: true,
      ),
      isTrue,
    );
  });
}
