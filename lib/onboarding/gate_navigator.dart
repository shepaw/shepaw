import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/pairing_endpoints.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/cli_host.dart';
import '../services/cli_pouch.dart';
import '../services/logger_service.dart';
import '../storage/pouch_credential_store.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_session.dart';
import '../utils/platform_utils.dart';
import 'credential_restore.dart';
import 'gate_entry.dart';
import 'gate_entry.dart';
import 'host_entry.dart';
import 'host_install_controller.dart';
import 'host_install_screen.dart';
import 'phone_host_store.dart';

/// 调用方带过来的上下文。比如 keeper 把人带到解锁页时，要说是主机重启了。
class GateHint {
  const GateHint({this.unlockReason});

  final UnlockReason? unlockReason;
}

/// 所有「进门」的唯一入口：Splash、退出登录、keeper 要密码、切换主机之后。
///
/// 它只负责三件事：把 [resolveGate] 需要的输入收齐、把结果记下来、然后离开
/// 当前页。判断本身在那个纯函数里，改判断请改那里，别在这里加分支。
class GateNavigator {
  /// [minDisplay] 用来避免启动页闪一下：离开当前页之前至少等这么久。
  static Future<void> go(
    BuildContext context, {
    GateHint? hint,
    Duration minDisplay = Duration.zero,
    ValueNotifier<GatePhase>? phase,
    HostInstallController? install,
    Duration inPlaceBudget = const Duration(seconds: 2),
  }) async {
    final started = DateTime.now();
    final isDesktop = isDesktopPlatform;
    final session = await PouchSessionStore.readActive();
    final host = session == null
        ? null
        : await PeerStorageService().getPeerById(session.hostPeerId);
    final mode = await HostModeStore.read();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // 手机没有本机 shepaw。
    final LocalCliStatus cliStatus;
    final CliHostEndpoint? cli;
    if (isDesktop) {
      cliStatus = await CliHost.probe();
      cli = await CliHost.detect();
    } else {
      cliStatus = LocalCliStatus.notInstalled;
      cli = null;
    }

    // 只有「主机就是这台电脑」时才问密码状态。问不到（超时 / 抛错）留 null，
    // 交给决策表去进「准备主机」，不要当成「没设过密码」把人推进建袋子页。
    bool? localPasswordSet;
    if (isDesktop &&
        mode != HostMode.remote &&
        cli != null &&
        cliStatus == LocalCliStatus.running) {
      try {
        localPasswordSet = await CliPouch.passwordIsSet(cli.binary)
            .timeout(const Duration(seconds: 3));
      } catch (error) {
        LoggerService().warning(
          'pouch password status failed: $error',
          tag: 'Gate',
        );
      }
    }

    final credentialValid = session != null &&
        await PouchCredentialStore.instance.readValid(
              hostPeerId: session.hostPeerId,
              pouchId: session.pouchId,
              nowMs: nowMs,
            ) !=
            null;

    final rememberedHostId =
        isDesktop ? session?.hostPeerId : await PhoneHostStore.read();

    final entry = resolveGate(
      isDesktop: isDesktop,
      mode: mode,
      cli: cliStatus,
      localPasswordSet: localPasswordSet,
      session: session,
      credentialValid: credentialValid,
      rememberedHostId: rememberedHostId,
      nowMs: nowMs,
      localCliFingerprint: cli?.fingerprint,
      sessionHostFingerprint: host?.fingerprint,
    );

    final record = entry.recordMode;
    if (record != null) await HostModeStore.write(record);
    if (!context.mounted) return;
    LoggerService().info(
      'gate ${entry.runtimeType} mode=$mode cli=$cliStatus '
      'passwordSet=$localPasswordSet credential=$credentialValid',
      tag: 'Gate',
    );

    await _hold(context, started, minDisplay);
    if (!context.mounted) return;
    await _dispatch(
      context,
      entry,
      cli: cli,
      cliStatus: cliStatus,
      session: session,
      host: host,
      hint: hint,
      phase: phase,
      install: install,
      inPlaceBudget: inPlaceBudget,
    );
  }

  static Future<void> _hold(
    BuildContext context,
    DateTime started,
    Duration minDisplay,
  ) async {
    final elapsed = DateTime.now().difference(started);
    if (elapsed >= minDisplay) return;
    await Future<void>.delayed(minDisplay - elapsed);
  }

  static Future<void> _dispatch(
    BuildContext context,
    GateEntry entry, {
    required CliHostEndpoint? cli,
    required LocalCliStatus cliStatus,
    required PouchSession? session,
    required PairedPeer? host,
    GateHint? hint,
    ValueNotifier<GatePhase>? phase,
    HostInstallController? install,
    Duration inPlaceBudget = const Duration(seconds: 2),
  }) async {
    switch (entry) {
      case GoHome():
        await _enterHome(context, session: session, cli: cli, host: host);

      case TryRestore(:final hostPeerId, :final fallback):
        final result = await productionCredentialRestore(cli: cli)
                .run(hostPeerId: hostPeerId);
        if (!context.mounted) return;
        switch (result) {
          case RestoreResult.restored:
            _replace(context, '/home');
          case RestoreResult.rejected:
            await _unlock(
              context,
              hostPeerId: hostPeerId,
              reason: UnlockReason.credentialRejected,
              cli: cli,
            );
          case RestoreResult.unreachable:
            await _unlock(
              context,
              hostPeerId: hostPeerId,
              reason: hint?.unlockReason ?? UnlockReason.expired,
              cli: cli,
            );
          case RestoreResult.none:
            await _dispatch(
              context,
              fallback,
              cli: cli,
              cliStatus: cliStatus,
              session: session,
              host: host,
              hint: hint,
              phase: phase,
              install: install,
              inPlaceBudget: inPlaceBudget,
            );
        }

      case GoWelcome():
        _replace(context, isDesktopPlatform ? '/welcome' : '/remote-connect');

      case GoHostInstall(:final reason):
        await _hostInstall(
          context,
          reason: reason,
          cli: cli,
          cliStatus: cliStatus,
          session: session,
          host: host,
          phase: phase,
          install: install,
          inPlaceBudget: inPlaceBudget,
        );

      case GoCreatePassword():
        _replace(context, '/create-password');

      case GoUnlock(:final hostPeerId, :final reason):
        await _unlock(
          context,
          hostPeerId: hostPeerId,
          reason: hint?.unlockReason ?? reason,
          cli: cli,
        );
    }
  }

  /// 桌面本机主机的 peer id 要等配对之后才有。
  static Future<String> _localHostId(CliHostEndpoint? cli) async {
    if (cli == null) return '';
    try {
      return (await CliHost.ensurePaired(cli)).id;
    } catch (error) {
      LoggerService().warning('ensurePaired failed: $error', tag: 'Gate');
      return '';
    }
  }

  static Future<void> _unlock(
    BuildContext context, {
    required String hostPeerId,
    required UnlockReason reason,
    required CliHostEndpoint? cli,
  }) async {
    final id = hostPeerId.trim().isEmpty ? await _localHostId(cli) : hostPeerId;
    if (!context.mounted) return;
    _replace(
      context,
      '/unlock',
      arguments: UnlockArgs(hostPeerId: id, reason: reason),
    );
  }

  /// 登录态还有效：先把本机主机的地址收回环，再进主页。
  static Future<void> _enterHome(
    BuildContext context, {
    required PouchSession? session,
    required CliHostEndpoint? cli,
    required PairedPeer? host,
  }) async {
    if (cli != null && sameFingerprint(cli.fingerprint, host?.fingerprint)) {
      try {
        await CliHost.attach(cli);
      } on HostUnresponsiveException {
        if (!context.mounted) return;
        _replace(
          context,
          '/pouch',
          arguments: const PouchLoginArgs(hostUnresponsive: true),
        );
        return;
      }
    } else if (session != null) {
      PouchChannel.install(session);
      if (host != null) {
        unawaited(
          PeerConnectionManager.instance.connectToPeer(host).catchError(
            (Object error, StackTrace stack) {
              LoggerService().warning(
                'host connect failed: $error',
                tag: 'Gate',
              );
            },
          ),
        );
      }
    }
    if (!context.mounted) return;
    _replace(context, '/home');
  }

  static Future<void> _hostInstall(
    BuildContext context, {
    required HostInstallReason reason,
    required CliHostEndpoint? cli,
    required LocalCliStatus cliStatus,
    required PouchSession? session,
    required PairedPeer? host,
    ValueNotifier<GatePhase>? phase,
    HostInstallController? install,
    Duration inPlaceBudget = const Duration(seconds: 2),
  }) async {
    if (reason == HostInstallReason.unresponsive) {
      _replace(
        context,
        '/pouch',
        arguments: const PouchLoginArgs(hostUnresponsive: true),
      );
      return;
    }
    final controller = install ??
        HostInstallController(
          reason: reason == HostInstallReason.firstInstall
              ? HostInstallReason.firstInstall
              : HostInstallReason.notRunning,
          log: (message) => LoggerService().info(message, tag: 'HostInstall'),
        );
    phase?.value = GatePhase.startingHost;
    unawaited(controller.start());
    final deadline = DateTime.now().add(inPlaceBudget);
    while (!controller.done &&
        controller.failedStep == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!context.mounted) return;
    if (!controller.done && controller.failedStep == null) {
      _replaceHostInstall(context, controller);
      return;
    }
    if (controller.done) {
      await go(context, minDisplay: Duration.zero);
      return;
    }
    _replaceHostInstall(context, controller);
  }

  static void _replaceHostInstall(
    BuildContext context,
    HostInstallController controller,
  ) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/host-install'),
        builder: (_) => HostInstallScreen(controller: controller),
      ),
    );
  }
}

void _replace(BuildContext context, String route, {Object? arguments}) {
  Navigator.of(context).pushReplacementNamed(route, arguments: arguments);
}
