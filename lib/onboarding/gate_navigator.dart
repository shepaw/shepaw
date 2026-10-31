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
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import '../utils/platform_utils.dart';
import 'credential_restore.dart';
import 'gate_entry.dart';
import 'host_entry.dart';
import 'phone_auth_screen.dart';
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
  }) async {
    switch (entry) {
      case GoHome():
        await _enterHome(context, session: session, cli: cli, host: host);

      case TryRestore(:final hostPeerId, :final fallback):
        final result =
            await _restore(cli: cli).run(hostPeerId: hostPeerId);
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
            );
        }

      case GoWelcome():
        _replace(context, isDesktopPlatform ? '/host-setup' : '/remote-connect');

      case GoHostInstall(:final reason):
        await _hostInstall(
          context,
          reason: reason,
          cli: cli,
          cliStatus: cliStatus,
          session: session,
          host: host,
        );

      case GoCreatePassword():
        _replace(context, '/pouch-init');

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
    if (!isDesktopPlatform) {
      _replace(context, '/phone-login', arguments: PhoneAuthArgs(hostPeerId: id));
      return;
    }
    if (hostPeerId.trim().isEmpty) {
      _replace(context, '/pouch-unlock');
      return;
    }
    _replace(
      context,
      '/pouch',
      arguments: PouchLoginArgs(hostPeerId: id),
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
  }) async {
    if (reason == HostInstallReason.firstInstall) {
      _replace(context, '/host-setup');
      return;
    }
    if (reason == HostInstallReason.unresponsive) {
      _replace(
        context,
        '/pouch',
        arguments: const PouchLoginArgs(hostUnresponsive: true),
      );
      return;
    }
    await _autoLocal(context, cli: cli, session: session, host: host);
  }

  /// 主机装了没跑：自动 `shepaw start`，再按老路子决定去哪。
  ///
  /// TODO(L4)：这里会被 `HostInstallScreen` 取代，那个页面有分步进度和失败出口。
  static Future<void> _autoLocal(
    BuildContext context, {
    required CliHostEndpoint? cli,
    required PouchSession? session,
    required PairedPeer? host,
  }) async {
    var running = cli;
    final binary = running?.binary ?? await CliHost.resolveBinary();
    if (!context.mounted) return;
    if (binary == null) {
      _replace(context, '/host-setup');
      return;
    }
    final l10n = AppLocalizations.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.hostStart_starting),
      ),
    ));
    final started = DateTime.now();
    try {
      await CliHost.start(binary);
    } catch (error) {
      LoggerService().error('shepaw start failed', tag: 'Gate', error: error);
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) _replace(context, '/host-setup');
      return;
    }
    final elapsed = DateTime.now().difference(started);
    if (elapsed < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(seconds: 2) - elapsed);
    }
    if (context.mounted) Navigator.of(context).pop();
    running = await CliHost.detect();
    if (!context.mounted) return;
    if (running == null) {
      _replace(context, '/host-setup');
      return;
    }
    try {
      await CliHost.attach(running);
    } on HostUnresponsiveException {
      if (!context.mounted) return;
      _replace(
        context,
        '/pouch',
        arguments: const PouchLoginArgs(hostUnresponsive: true),
      );
      return;
    }
    final current = await PouchSessionStore.readActive();
    final currentHost = current == null
        ? null
        : await PeerStorageService().getPeerById(current.hostPeerId);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!context.mounted) return;
    if (current != null &&
        current.isLoggedIn(now) &&
        sameFingerprint(running.fingerprint, currentHost?.fingerprint)) {
      _replace(context, '/home');
      return;
    }
    bool? initialized;
    try {
      initialized = await CliPouch.passwordIsSet(running.binary)
          .timeout(const Duration(seconds: 3));
    } catch (error) {
      LoggerService().warning('password status failed: $error', tag: 'Gate');
    }
    if (!context.mounted) return;
    if (initialized == null) {
      _replace(
        context,
        '/pouch',
        arguments: const PouchLoginArgs(hostUnresponsive: true),
      );
      return;
    }
    _replace(context, initialized ? '/pouch-unlock' : '/pouch-init');
  }

  static CredentialRestore _restore({required CliHostEndpoint? cli}) {
    return CredentialRestore(
      readSession: PouchSessionStore.readActive,
      lookupPeer: (hostPeerId) =>
          PeerStorageService().getPeerById(hostPeerId),
      readCredential: ({
        required String hostPeerId,
        required String pouchId,
        required int nowMs,
      }) async {
        final saved = await PouchCredentialStore.instance.readValid(
          hostPeerId: hostPeerId,
          pouchId: pouchId,
          nowMs: nowMs,
        );
        return saved?.credential;
      },
      connect: (peer, {required bool redial}) async {
        // 本机主机走 attach：它顺手把地址收回环，老 session 里的旧端口也一起修好。
        final local = cli ?? await CliHost.detect();
        if (local != null && sameFingerprint(local.fingerprint, peer.fingerprint)) {
          await CliHost.attach(local);
          return;
        }
        if (redial) {
          await PeerConnectionManager.instance.disconnectPeer(peer.id);
        }
        await PeerConnectionManager.instance.connectToPeer(
          peer,
          ignoreTieBreak: true,
        );
      },
      login: ({
        required String hostPeerId,
        required String pouchId,
        required String credential,
      }) =>
          requestPouchLogin(
        hostPeerId: hostPeerId,
        pouchId: pouchId,
        credential: credential,
      ),
      persist: (next) async {
        await PouchSessionStore(await PouchSessionStore.appFile()).save(next);
      },
      install: PouchChannel.install,
      saveCredential: ({
        required String hostPeerId,
        required String pouchId,
        required String credential,
        required int expiresAtMs,
      }) =>
          PouchCredentialStore.instance.save(
        hostPeerId: hostPeerId,
        pouchId: pouchId,
        credential: credential,
        expiresAtMs: expiresAtMs,
      ),
      dropCredential: (hostPeerId) =>
          PouchCredentialStore.instance.delete(hostPeerId),
      log: (message) => LoggerService().info(message, tag: 'CredentialRestore'),
    );
  }
}

void _replace(BuildContext context, String route, {Object? arguments}) {
  Navigator.of(context).pushReplacementNamed(route, arguments: arguments);
}
