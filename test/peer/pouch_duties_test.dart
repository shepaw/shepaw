import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/pouch_duties.dart';

void main() {
  test('客户端不养惜宝、不跑时钟，只执行本机命令', () {
    expect(PouchDuties.runsLocalShe(true), isTrue);
    expect(PouchDuties.runsLocalShe(false), isFalse);
    expect(PouchDuties.runsScheduler(false), isFalse);
    expect(PouchDuties.schedulerFollowsAppBackground(true), isFalse);
    expect(PouchDuties.schedulerFollowsAppBackground(false), isTrue);

    expect(PouchDuties.cliAllowed(isHost: true, namespace: 'store'), isTrue);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'os'), isTrue);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'help'), isTrue);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'store'), isFalse);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'chat'), isFalse);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'workflow'), isFalse);
    expect(PouchDuties.cliAllowed(isHost: false, namespace: 'context'), isFalse);

    expect(
      PouchDuties.adoptHostSheRow(
        isHost: false,
        hostPeerId: 'host-1',
        peerId: 'host-1',
        remoteAgentId: 'she-builtin-agent-001',
        sheIdTakenBySomeoneElse: false,
      ),
      isTrue,
    );
    expect(
      PouchDuties.adoptHostSheRow(
        isHost: true,
        hostPeerId: null,
        peerId: 'hub',
        remoteAgentId: 'she-builtin-agent-001',
        sheIdTakenBySomeoneElse: false,
      ),
      isFalse,
    );
    expect(
      PouchDuties.adoptHostSheRow(
        isHost: false,
        hostPeerId: 'host-1',
        peerId: 'other',
        remoteAgentId: 'she-builtin-agent-001',
        sheIdTakenBySomeoneElse: false,
      ),
      isFalse,
    );
    expect(
      PouchDuties.adoptHostSheRow(
        isHost: false,
        hostPeerId: 'host-1',
        peerId: 'host-1',
        remoteAgentId: 'she-builtin-agent-001',
        sheIdTakenBySomeoneElse: true,
      ),
      isFalse,
    );
  });
}
