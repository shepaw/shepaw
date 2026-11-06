import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';

void main() {
  test('P4: node session channel id is the psess_ shell', () {
    expect(flowSessionChannelId('flow_deadbe12_impl'),
        'psess_flow_deadbe12_impl');
    expect(flowSessionChannelId('  flow_deadbe12_impl  '),
        'psess_flow_deadbe12_impl');
  });

  test('P4: agent id falls back to the Hub-side id when no local row exists',
      () async {
    expect(
      await resolveFlowAgentLocalId(
        peerId: 'p1',
        remoteAgentId: 'agent-7',
      ),
      'agent-7',
    );
    expect(
      await resolveFlowAgentLocalId(peerId: 'p1', remoteAgentId: ''),
      '',
    );
  });
}
