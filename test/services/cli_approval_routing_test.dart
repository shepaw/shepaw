import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/os/os_executor.dart' as os_exec;
import 'package:shepaw/services/cli_approval_coordinator.dart';

void main() {
  setUp(() {
    CliApprovalCoordinator.instance.resetForTest();
  });

  CliApprovalHandler _handler(void Function(String) onAsked) =>
      (tool, flags, risk, {required String? channelId, required String? agentId}) async {
        onAsked(channelId ?? '');
        return true;
      };

  test('approval goes to the owning channel, not the last registered one',
      () async {
    final asked = <String>[];
    CliApprovalCoordinator.instance.register(
      _handler(asked.add),
      channelId: 'ch-a',
    );
    CliApprovalCoordinator.instance.register(
      _handler(asked.add),
      channelId: 'ch-b',
    );

    // ch-b 是最后登记的；请求属于 ch-a，只能打到 ch-a 的 handler。
    final approved = await CliApprovalCoordinator.instance.request(
      'peer.list',
      const {},
      os_exec.RiskLevel.lowRisk,
      channelId: 'ch-a',
      agentId: 'agent-a',
    );

    expect(approved, isTrue);
    expect(asked, ['ch-a']);
  });

  test('re-registering under a new channel moves the handler', () async {
    final asked = <String>[];
    final shared = _handler(asked.add);
    CliApprovalCoordinator.instance.register(shared, channelId: 'ch-a');
    // 原位换频道：同一个 controller 重新登记到 ch-b。
    CliApprovalCoordinator.instance.register(shared, channelId: 'ch-b');

    await CliApprovalCoordinator.instance.request(
      'peer.list',
      const {},
      os_exec.RiskLevel.lowRisk,
      channelId: 'ch-b',
      agentId: 'agent-a',
    );
    expect(asked, ['ch-b']);
  });

  test('approval with no owning channel is denied instead of misfiled',
      () async {
    var asked = 0;
    CliApprovalCoordinator.instance.register(
      (tool, flags, risk,
          {required String? channelId, required String? agentId}) async {
        asked += 1;
        return true;
      },
      channelId: 'ch-a',
    );

    final approved = await CliApprovalCoordinator.instance.request(
      'peer.list',
      const {},
      os_exec.RiskLevel.lowRisk,
      channelId: null,
      agentId: 'agent-a',
    );
    expect(approved, isFalse);
    expect(asked, 0);
  });
}
