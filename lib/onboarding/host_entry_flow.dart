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
import '../storage/pouch_login.dart';
import '../storage/pouch_session.dart';
import 'host_entry.dart';

/// 按 [resolveHostEntry] 的结果离开当前页。
class HostEntryNavigator {
  static Future<void> go(
    BuildContext context, {
    required bool isDesktop,
  }) async {
    final session = await PouchSessionStore.readActive();
    final host = session == null
        ? null
        : await PeerStorageService().getPeerById(session.hostPeerId);
    final mode = await HostModeStore.read();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final loggedIn = session != null && session.isLoggedIn(nowMs);
    // 手机没有本机 shepaw，解锁后去连远端主机。
    final LocalCliStatus cliStatus;
    final CliHostEndpoint? cli;
    if (isDesktop) {
      cliStatus = await CliHost.probe();
      cli = await CliHost.detect();
    } else {
      cliStatus = LocalCliStatus.notInstalled;
      cli = null;
    }
    final hasPairedHost = !isDesktop &&
        !loggedIn &&
        (await PeerStorageService().loadAllPeers())
            .any((peer) => !peer.isBlocked);
    final entry = resolveHostEntry(
      isDesktop: isDesktop,
      mode: mode,
      cli: cliStatus,
      session: session,
      nowMs: nowMs,
      localCliFingerprint: cli?.fingerprint,
      sessionHostFingerprint: host?.fingerprint,
      hasPairedHost: hasPairedHost,
    );
    final record = entry.recordMode;
    if (record != null) await HostModeStore.write(record);
    if (!context.mounted) return;
    LoggerService().info(
      'host entry ${entry.runtimeType} mode=$mode cli=$cliStatus',
      tag: 'HostEntry',
    );
    final here = ModalRoute.of(context)?.settings.name;
    switch (entry) {
      case ShowHostSetup():
        if (here == '/host-setup') return;
        _replace(context, '/host-setup');
      case ShowPouchChooser():
        _replace(context, '/pouch');
      case ShowRemoteConnect():
        if (here == '/remote-connect') return;
        _replace(context, '/remote-connect');
      case EnterHome():
        await _enterHome(context, session: session, cli: cli, host: host);
      case AutoLocal(:final needsStart):
        await _autoLocal(context, needsStart: needsStart, cli: cli);
    }
  }
}

void _replace(BuildContext context, String route, {Object? arguments}) {
  Navigator.of(context).pushReplacementNamed(route, arguments: arguments);
}

Future<void> _enterHome(
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
              tag: 'HostEntry',
            );
          },
        ),
      );
    }
  }
  if (!context.mounted) return;
  _replace(context, '/home');
}

Future<void> _autoLocal(
  BuildContext context, {
  required bool needsStart,
  required CliHostEndpoint? cli,
}) async {
  var running = cli;
  if (needsStart) {
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
      LoggerService()
          .error('shepaw start failed', tag: 'HostEntry', error: error);
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
  }
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
  final session = await PouchSessionStore.readActive();
  final host = session == null
      ? null
      : await PeerStorageService().getPeerById(session.hostPeerId);
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!context.mounted) return;
  if (session != null &&
      session.isLoggedIn(now) &&
      sameFingerprint(running.fingerprint, host?.fingerprint)) {
    _replace(context, '/home');
    return;
  }
  final binary = running.binary;
  final initialized = await CliPouch.passwordIsSet(binary);
  if (!context.mounted) return;
  _replace(context, initialized ? '/pouch-unlock' : '/pouch-init');
}
