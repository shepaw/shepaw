import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/host_entry.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  PouchSession live({int expiresAtMs = 9000}) {
    return PouchSession(
      hubUrl: 'ws://127.0.0.1:18794/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'peer-1',
      token: 'login-token',
      sessionId: 'sid-1',
      expiresAtMs: expiresAtMs,
    );
  }

  HostEntry resolve({
    bool isDesktop = true,
    HostMode mode = HostMode.unset,
    LocalCliStatus cli = LocalCliStatus.notInstalled,
    PouchSession? session,
    int nowMs = 10,
    String? localCliFingerprint,
    String? sessionHostFingerprint,
  }) {
    return resolveHostEntry(
      isDesktop: isDesktop,
      mode: mode,
      cli: cli,
      session: session,
      nowMs: nowMs,
      localCliFingerprint: localCliFingerprint,
      sessionHostFingerprint: sessionHostFingerprint,
    );
  }

  test('手机：登录态有效进主页，否则去选袋子', () {
    expect(resolve(isDesktop: false, session: live()), isA<EnterHome>());
    expect(resolve(isDesktop: false), isA<ShowPouchChooser>());
    expect(
      resolve(isDesktop: false, session: live(expiresAtMs: 10), nowMs: 10),
      isA<ShowPouchChooser>(),
    );
  });

  test('桌面选过远端：登录态有效进主页，否则去选袋子', () {
    expect(
      resolve(mode: HostMode.remote, session: live()),
      isA<EnterHome>(),
    );
    expect(resolve(mode: HostMode.remote), isA<ShowPouchChooser>());
    expect(
      resolve(
        mode: HostMode.remote,
        session: live(expiresAtMs: 10),
        nowMs: 10,
      ),
      isA<ShowPouchChooser>(),
    );
  });

  test('桌面选过本机且 CLI 在跑：指纹对得上进主页，否则先配对', () {
    final home = resolve(
      mode: HostMode.thisComputer,
      cli: LocalCliStatus.running,
      session: live(),
      localCliFingerprint: 'fp',
      sessionHostFingerprint: 'FP',
    );
    expect(home, isA<EnterHome>());

    final again = resolve(
      mode: HostMode.thisComputer,
      cli: LocalCliStatus.running,
      session: live(),
      localCliFingerprint: 'other',
      sessionHostFingerprint: 'fp',
    );
    expect(again, isA<AutoLocal>());
    expect((again as AutoLocal).needsStart, isFalse);

    final expired = resolve(
      mode: HostMode.thisComputer,
      cli: LocalCliStatus.running,
      session: live(expiresAtMs: 10),
      nowMs: 10,
      localCliFingerprint: 'fp',
      sessionHostFingerprint: 'fp',
    );
    expect(expired, isA<AutoLocal>());
    expect((expired as AutoLocal).needsStart, isFalse);
  });

  test('桌面选过本机：没跑就启动，没装就去设置', () {
    final stopped = resolve(
      mode: HostMode.thisComputer,
      cli: LocalCliStatus.installedStopped,
      session: live(),
    );
    expect(stopped, isA<AutoLocal>());
    expect((stopped as AutoLocal).needsStart, isTrue);
    expect(
      resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.notInstalled,
        session: live(),
      ),
      isA<ShowHostSetup>(),
    );
  });

  test('老用户没选过：CLI 在就记成本机，再按本机规则走', () {
    final running = resolve(
      cli: LocalCliStatus.running,
      session: live(),
      localCliFingerprint: 'fp',
      sessionHostFingerprint: 'fp',
    );
    expect(running, isA<EnterHome>());
    expect(running.recordMode, HostMode.thisComputer);

    final stopped = resolve(cli: LocalCliStatus.installedStopped);
    expect(stopped, isA<AutoLocal>());
    expect((stopped as AutoLocal).needsStart, isTrue);
    expect(stopped.recordMode, HostMode.thisComputer);
  });

  test('没装 CLI：登录的主机不是本机就记成远端并进主页，否则去设置', () {
    final remote = resolve(
      session: live(),
      localCliFingerprint: null,
      sessionHostFingerprint: 'somewhere',
    );
    expect(remote, isA<EnterHome>());
    expect(remote.recordMode, HostMode.remote);

    expect(resolve(), isA<ShowHostSetup>());
    expect(
      resolve(session: live(expiresAtMs: 10), nowMs: 10),
      isA<ShowHostSetup>(),
    );
  });
}
