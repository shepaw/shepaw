import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/gate_entry.dart';
import 'package:shepaw/onboarding/host_entry.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  const localFp = 'fp-local';
  const remoteFp = 'fp-remote';

  const now = 1000;

  PouchSession live({
    String hostPeerId = 'peer-local',
    int expiresAtMs = now + 5000,
  }) {
    return PouchSession(
      hubUrl: 'ws://127.0.0.1:18794/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: hostPeerId,
      token: 'login-token',
      sessionId: 'sid-1',
      expiresAtMs: expiresAtMs,
    );
  }

  /// 过期但还记得是哪只袋子的会话。
  PouchSession expired({String hostPeerId = 'peer-local'}) =>
      live(hostPeerId: hostPeerId, expiresAtMs: now - 1);

  GateEntry resolve({
    bool isDesktop = true,
    HostMode mode = HostMode.unset,
    LocalCliStatus cli = LocalCliStatus.notInstalled,
    bool? localPasswordSet,
    PouchSession? session,
    bool credentialValid = false,
    String? rememberedHostId,
    String? localCliFingerprint = localFp,
    String? sessionHostFingerprint = localFp,
    int nowMs = now,
  }) {
    return resolveGate(
      isDesktop: isDesktop,
      mode: mode,
      cli: cli,
      localPasswordSet: localPasswordSet,
      session: session,
      credentialValid: credentialValid,
      rememberedHostId: rememberedHostId,
      nowMs: nowMs,
      localCliFingerprint: localCliFingerprint,
      sessionHostFingerprint: sessionHostFingerprint,
    );
  }

  group('第 1 行 · 登录态有效', () {
    test('手机不管凭据，直接进主页', () {
      expect(
        resolve(isDesktop: false, session: live(), rememberedHostId: 'peer-1'),
        isA<GoHome>(),
      );
    });

    test('桌面远端主机，直接进主页', () {
      expect(
        resolve(mode: HostMode.remote, session: live()),
        isA<GoHome>(),
      );
    });

    test('桌面本机，会话主机就是本机 CLI，直接进主页', () {
      expect(
        resolve(
          mode: HostMode.thisComputer,
          cli: LocalCliStatus.running,
          localPasswordSet: true,
          session: live(),
        ),
        isA<GoHome>(),
      );
    });

    test('mode 还是 unset 时顺手记成 thisComputer', () {
      final entry = resolve(
        mode: HostMode.unset,
        cli: LocalCliStatus.running,
        localPasswordSet: true,
        session: live(),
      );
      expect(entry, isA<GoHome>());
      expect(entry.recordMode, HostMode.thisComputer);
    });
  });

  group('第 2–4 行 · 手机', () {
    test('没配过主机，去扫码加入', () {
      expect(
        resolve(isDesktop: false, rememberedHostId: null),
        isA<GoWelcome>(),
      );
      expect(
        resolve(isDesktop: false, rememberedHostId: '   '),
        isA<GoWelcome>(),
      );
    });

    test('有凭据就先静默续期，续不回来再解锁', () {
      final entry = resolve(
        isDesktop: false,
        rememberedHostId: 'peer-1',
        credentialValid: true,
      );
      expect(entry, isA<TryRestore>());
      final restore = entry as TryRestore;
      expect(restore.hostPeerId, 'peer-1');
      expect(restore.fallback, isA<GoUnlock>());
      expect((restore.fallback as GoUnlock).hostPeerId, 'peer-1');
    });

    test('没有凭据直接解锁', () {
      final entry = resolve(isDesktop: false, rememberedHostId: 'peer-1');
      expect(entry, isA<GoUnlock>());
      expect((entry as GoUnlock).reason, UnlockReason.expired);
    });
  });

  group('第 5 行 · 桌面 unset 但 CLI 在跑', () {
    test('老用户无感升级，按本机主机处理并记下 thisComputer', () {
      final entry = resolve(
        mode: HostMode.unset,
        cli: LocalCliStatus.running,
        localPasswordSet: true,
        session: expired(),
      );
      expect(entry, isA<GoUnlock>());
      expect(entry.recordMode, HostMode.thisComputer);
    });

    test('探测不到密码状态时不盲跳解锁页，去准备主机', () {
      final entry = resolve(
        mode: HostMode.unset,
        cli: LocalCliStatus.running,
        localPasswordSet: null,
        session: expired(),
      );
      expect(entry, isA<GoHostInstall>());
      expect(
        (entry as GoHostInstall).reason,
        HostInstallReason.unresponsive,
      );
    });
  });

  group('第 6 行 · 桌面 unset、CLI 没跑、登录过远端主机', () {
    test('记成 remote 并去解锁那台远端主机，不推去本机建袋子', () {
      final entry = resolve(
        mode: HostMode.unset,
        cli: LocalCliStatus.notInstalled,
        session: expired(hostPeerId: 'peer-remote'),
        sessionHostFingerprint: remoteFp,
      );
      expect(entry, isA<GoUnlock>());
      expect(entry.recordMode, HostMode.remote);
      expect((entry as GoUnlock).hostPeerId, 'peer-remote');
    });

    test('会话主机就是本机时仍然先问主机放哪', () {
      expect(
        resolve(
          mode: HostMode.unset,
          cli: LocalCliStatus.installedStopped,
          session: expired(),
        ),
        isA<GoWelcome>(),
      );
    });
  });

  group('第 7–8 行 · 桌面 remote', () {
    test('有凭据先续期', () {
      final entry = resolve(
        mode: HostMode.remote,
        session: expired(hostPeerId: 'peer-remote'),
        credentialValid: true,
      );
      expect(entry, isA<TryRestore>());
      expect((entry as TryRestore).hostPeerId, 'peer-remote');
    });

    test('没凭据就解锁', () {
      final entry = resolve(
        mode: HostMode.remote,
        session: expired(hostPeerId: 'peer-remote'),
      );
      expect(entry, isA<GoUnlock>());
      expect((entry as GoUnlock).hostPeerId, 'peer-remote');
    });

    test('连会话都没有就去欢迎页', () {
      expect(resolve(mode: HostMode.remote), isA<GoWelcome>());
    });
  });

  group('第 9 行 · 桌面首次', () {
    test('没选过主机位置、CLI 也没跑，先问主机放哪', () {
      expect(
        resolve(
          mode: HostMode.unset,
          cli: LocalCliStatus.notInstalled,
        ),
        isA<GoWelcome>(),
      );
    });

    test('装了但没跑同样先问：启动时的自带 CLI 不算用户的选择', () {
      expect(
        resolve(
          mode: HostMode.unset,
          cli: LocalCliStatus.installedStopped,
        ),
        isA<GoWelcome>(),
      );
    });
  });

  group('第 9.5 行 · 桌面本机还没有可用口令', () {
    test('装了 shepaw 但 Hub 没跑，直接去建袋子设密码', () {
      expect(
        resolve(
          mode: HostMode.thisComputer,
          cli: LocalCliStatus.installedStopped,
          localPasswordSet: false,
        ),
        isA<GoCreatePassword>(),
        reason: 'Hub 要 active_pouch 才起得来，准备主机那条路是死循环',
      );
    });

    test('CLI 在跑但没设过密码，同样去建袋子', () {
      expect(
        resolve(
          mode: HostMode.thisComputer,
          cli: LocalCliStatus.running,
          localPasswordSet: false,
        ),
        isA<GoCreatePassword>(),
      );
    });

    test('mode 还是 unset、CLI 在跑时记下 thisComputer 再去建袋子', () {
      final entry = resolve(
        mode: HostMode.unset,
        cli: LocalCliStatus.running,
        localPasswordSet: false,
      );
      expect(entry, isA<GoCreatePassword>());
      expect(entry.recordMode, HostMode.thisComputer);
    });

    test('没装 shepaw 时先去准备主机装 CLI', () {
      final entry = resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.notInstalled,
        localPasswordSet: false,
      );
      expect(entry, isA<GoHostInstall>());
      expect((entry as GoHostInstall).reason, HostInstallReason.firstInstall);
    });

    test('探测不到密码状态时不猜，仍按原规则走', () {
      expect(
        resolve(
          mode: HostMode.thisComputer,
          cli: LocalCliStatus.installedStopped,
          localPasswordSet: null,
        ),
        isA<GoHostInstall>(),
      );
    });

    test('还没选过主机位置时仍先问主机放哪，不擅自建本机袋子', () {
      expect(
        resolve(
          mode: HostMode.unset,
          cli: LocalCliStatus.installedStopped,
          localPasswordSet: false,
        ),
        isA<GoWelcome>(),
      );
    });
  });

  group('第 10–14 行 · 桌面 thisComputer', () {
    test('没装 shepaw 去准备主机', () {
      final entry = resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.notInstalled,
      );
      expect(entry, isA<GoHostInstall>());
      expect((entry as GoHostInstall).reason, HostInstallReason.firstInstall);
    });

    test('装了没跑去准备主机', () {
      final entry = resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.installedStopped,
      );
      expect(entry, isA<GoHostInstall>());
      expect((entry as GoHostInstall).reason, HostInstallReason.notRunning);
    });

    test('主机还没设密码，去设置', () {
      expect(
        resolve(
          mode: HostMode.thisComputer,
          cli: LocalCliStatus.running,
          localPasswordSet: false,
        ),
        isA<GoCreatePassword>(),
      );
    });

    test('有密码有凭据，先续期', () {
      final entry = resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.running,
        localPasswordSet: true,
        session: expired(),
        credentialValid: true,
      );
      expect(entry, isA<TryRestore>());
      expect((entry as TryRestore).hostPeerId, 'peer-local');
    });

    test('有密码没凭据，解锁本机主机', () {
      final entry = resolve(
        mode: HostMode.thisComputer,
        cli: LocalCliStatus.running,
        localPasswordSet: true,
        session: expired(),
      );
      expect(entry, isA<GoUnlock>());
      final unlock = entry as GoUnlock;
      expect(unlock.isLocalHost, isTrue);
      expect(unlock.reason, UnlockReason.expired);
    });
  });
}
