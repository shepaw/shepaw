import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../peer/services/local_cli_dial.dart';
import '../peer/models/paired_peer.dart';
import '../peer/models/pairing_payload.dart';
import '../onboarding/host_entry.dart';
import '../peer/pairing_endpoints.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_session.dart';

/// 本机主机在时限内没有连上。
class HostUnresponsiveException implements Exception {
  const HostUnresponsiveException();
}

/// 本机 `shepaw` CLI 正在听的主机。电脑上的 App 用它配对，不再走旧的仪表盘。
class CliHostEndpoint {
  const CliHostEndpoint({
    required this.port,
    required this.binary,
    required this.fingerprint,
    required this.pid,
  });

  final int port;
  final String binary;
  final String fingerprint;
  final int pid;

  String get localEndpoint => 'ws://127.0.0.1:$port/peer/ws';
}

class CliHost {
  static void installLookup() {
    lookupLocalCli ??= () async {
      final cli = await detect();
      final fingerprint = cli?.fingerprint.trim() ?? '';
      if (cli == null || fingerprint.isEmpty) return null;
      return (fingerprint: fingerprint, localEndpoint: cli.localEndpoint);
    };
  }

  static String hubRoot() => hubRootFromEnv(Platform.environment);

  /// 与 CLI `hub_root` 一致：`SHEPAW_HUB_HOME`，否则 XDG，否则
  /// `HOME` / `USERPROFILE` 下的 `.config/shepaw-hub`。
  static String hubRootFromEnv(Map<String, String> env, {p.Style? style}) =>
      cliHubRootFromEnv(env, style: style);

  static String homeDirFromEnv(Map<String, String> env) {
    for (final key in const ['HOME', 'USERPROFILE']) {
      final value = env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return '.';
  }

  /// 已安装的 CLI。macOS / Linux 在 `~/.shepaw/bin`，Windows 在
  /// `%LOCALAPPDATA%\Shepaw\bin`。
  static String? installedBinaryFromEnv(
    Map<String, String> env, {
    required bool windows,
    p.Style? style,
  }) {
    final ctx = _paths(style ?? (windows ? p.Style.windows : p.Style.posix));
    if (windows) {
      final local = env['LOCALAPPDATA'];
      if (local == null || local.isEmpty) return null;
      return ctx.join(local, 'Shepaw', 'bin', 'shepaw.exe');
    }
    return ctx.join(homeDirFromEnv(env), '.shepaw', 'bin', 'shepaw');
  }

  static List<String> debugBinaryCandidates(
    Map<String, String> env, {
    required bool windows,
    p.Style? style,
  }) {
    final ctx = _paths(style ?? (windows ? p.Style.windows : p.Style.posix));
    final name = windows ? 'shepaw.exe' : 'shepaw';
    final home = homeDirFromEnv(env);
    return [
      ctx.join(
          home, 'workspace', 'shepaw', 'shepaw-cli', 'target', 'debug', name),
      ctx.join(
          home, 'workspace', 'shepaw', 'shepaw-cli', 'target', 'release', name),
    ];
  }

  static p.Context _paths(p.Style? style) {
    return p.Context(
      style: style ?? (Platform.isWindows ? p.Style.windows : p.Style.posix),
    );
  }

  /// 手机连的是远端主机，本机没有 `shepaw` 可查。
  static bool get localCliSupported => !Platform.isAndroid && !Platform.isIOS;

  /// 找到二进制才问 `shepaw status --json`。老版本没有这个命令时，退回 [detect]。
  static Future<LocalCliStatus> probe() async {
    if (!localCliSupported) return LocalCliStatus.notInstalled;
    final binary = await resolveBinary();
    if (binary == null) return LocalCliStatus.notInstalled;
    try {
      final result = await Process.run(binary, const ['status', '--json']);
      if (result.exitCode == 0) {
        final decoded = jsonDecode(result.stdout.toString());
        if (decoded is Map && decoded['running'] == true) {
          return LocalCliStatus.running;
        }
        if (decoded is Map && decoded['running'] == false) {
          return LocalCliStatus.installedStopped;
        }
      }
    } catch (_) {}
    if (await detect() != null) return LocalCliStatus.running;
    return LocalCliStatus.installedStopped;
  }

  /// `peer-state.json` 带 `version`，而且里面的 pid 还活着，才算这台主机在跑。
  static Future<CliHostEndpoint?> detect() async {
    if (!localCliSupported) return null;
    final file = File('${hubRoot()}/peer-state.json');
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final version = (decoded['version'] as String?)?.trim() ?? '';
    final port = decoded['port'];
    final pid = decoded['pid'];
    if (version.isEmpty || port is! int || port <= 0) return null;
    if (pid is! int || pid <= 0 || !await _processAlive(pid)) return null;
    final binary = await resolveBinary();
    if (binary == null) return null;
    final fingerprint = (decoded['fingerprint'] as String?)?.trim() ?? '';
    return CliHostEndpoint(
      port: port,
      binary: binary,
      fingerprint: fingerprint,
      pid: pid,
    );
  }

  /// 执行 `shepaw start`，最多等 10 秒直到 [detect] 看到进程。
  static Future<void> start(String binary) async {
    await Process.start(
      binary,
      const ['start'],
      mode: ProcessStartMode.detached,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await detect() != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('shepaw 没有在时限内就绪');
  }

  /// 指纹已经配对过就直接用，并刷新回环地址。否则才签发新的配对码。
  static Future<PairedPeer> ensurePaired(CliHostEndpoint cli) async {
    installLookup();
    final fingerprint = cli.fingerprint.trim();
    if (fingerprint.isNotEmpty) {
      final existing = await _peerByFingerprint(fingerprint);
      if (existing != null) {
        await PeerStorageService().updateLocalEndpoint(
          existing.id,
          cli.localEndpoint,
        );
        return (await PeerStorageService().getPeerById(existing.id)) ??
            existing;
      }
    }
    final info = await mintPairing(cli);
    final peer = await PeerPairingService.instance.requestPairing(
      info,
      connectAfter: false,
    );
    final local = info.localEndpoint;
    if (local != null && local.isNotEmpty) {
      await PeerStorageService().updateLocalEndpoint(peer.id, local);
    }
    return (await PeerStorageService().getPeerById(peer.id)) ?? peer;
  }

  /// 进主页前把本机主机的地址收回环，并重拨。
  ///
  /// 连不上时抛 [HostUnresponsiveException]，调用方停在储物袋页。
  static Future<PairedPeer> attach(CliHostEndpoint cli) async {
    installLookup();
    final paired = await ensurePaired(cli);
    final storage = PeerStorageService();
    await storage.updateLocalEndpoint(paired.id, cli.localEndpoint);
    await storage.clearChannelEndpoint(paired.id);
    final stored = await storage.getPeerById(paired.id) ?? paired;
    final refreshed = stored.copyWith(
      localEndpoint: cli.localEndpoint,
      clearChannelEndpoint: true,
    );

    final session = await PouchSessionStore.readActive();
    if (session != null && session.hostPeerId == refreshed.id) {
      final next = session.hubUrl == cli.localEndpoint
          ? session
          : session.copyWith(hubUrl: cli.localEndpoint);
      if (next.hubUrl != session.hubUrl) {
        await PouchSessionStore(await PouchSessionStore.appFile()).save(next);
      }
      PouchChannel.install(next);
    }

    try {
      await PeerConnectionManager.instance
          .connectToPeer(refreshed, ignoreTieBreak: true)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const HostUnresponsiveException();
    }
    return refreshed;
  }

  /// 执行 `shepaw restart`，然后等到 [detect] 再次看到进程。
  static Future<void> restart(String binary) async {
    final result = await Process.run(binary, const ['restart']);
    if (result.exitCode != 0) {
      final detail = [
        result.stderr.toString().trim(),
        result.stdout.toString().trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      throw StateError(detail.isEmpty ? 'shepaw restart 失败' : detail);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await detect() != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('shepaw 没有在时限内就绪');
  }

  static Future<PairedPeer?> _peerByFingerprint(String fingerprint) async {
    final storage = PeerStorageService();
    final exact = await storage.getPeerByFingerprint(fingerprint);
    if (exact != null) return exact;
    final want = fingerprint.trim().toLowerCase();
    if (want.isEmpty) return null;
    final all = await storage.loadAllPeers();
    for (final peer in all) {
      if (peer.fingerprint.trim().toLowerCase() == want) return peer;
    }
    return null;
  }

  static Future<bool> _processAlive(int pid) async {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/FO',
        'CSV',
        '/NH',
      ]);
      final text = result.stdout.toString();
      return result.exitCode == 0 &&
          text.contains('$pid') &&
          !text.toUpperCase().contains('INFO:');
    }
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  }

  /// 先 `SHEPAW_BIN`，再安装目录，再 `which` / `where.exe`。
  /// 开发目录只在调试构建里查。手机不查本机 CLI。
  static Future<String?> resolveBinary() async {
    if (!localCliSupported) return null;
    final env = Platform.environment;
    final explicit = env['SHEPAW_BIN'];
    if (explicit != null &&
        explicit.isNotEmpty &&
        File(explicit).existsSync()) {
      return explicit;
    }
    final installed = installedBinaryFromEnv(env, windows: Platform.isWindows);
    if (installed != null && File(installed).existsSync()) return installed;
    final found = await _whichShepaw();
    if (found != null) return found;
    if (kDebugMode) {
      for (final path
          in debugBinaryCandidates(env, windows: Platform.isWindows)) {
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  static Future<String?> _whichShepaw() async {
    final ProcessResult result;
    try {
      if (Platform.isWindows) {
        result = await Process.run('where.exe', const ['shepaw']);
      } else {
        result = await Process.run('/usr/bin/which', const ['shepaw']);
      }
    } on ProcessException {
      return null;
    }
    if (result.exitCode != 0) return null;
    for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
      final found = line.trim();
      if (found.isNotEmpty && File(found).existsSync()) return found;
    }
    return null;
  }

  static Future<PeerPairingInfo> mintPairing(CliHostEndpoint host) async {
    final base = [
      'pair',
      '--host',
      '127.0.0.1',
      '--port',
      '${host.port}',
      '--local',
      host.localEndpoint,
    ];
    var result = await Process.run(host.binary, [...base, '--json']);
    if (result.exitCode != 0) {
      result = await Process.run(host.binary, base);
    }
    if (result.exitCode != 0) {
      final detail = [
        result.stderr.toString().trim(),
        result.stdout.toString().trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      throw StateError(detail.isEmpty ? 'shepaw pair 失败' : detail);
    }
    final info = pairingInfoFromOutput(result.stdout.toString());
    if (info == null) {
      throw StateError('shepaw pair 没有给出配对票据');
    }
    return info;
  }
}

/// `--json` 里的 `link`，或旧版本直接打印的 `shepaw://` 行。
PeerPairingInfo? pairingInfoFromOutput(String stdout) {
  for (final line in stdout.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final link = decoded['link'];
          if (link is String) {
            final info = PeerPairingInfo.tryParse(link);
            if (info != null) return info;
          }
        }
      } catch (_) {}
    }
    if (trimmed.startsWith('shepaw://')) {
      final info = PeerPairingInfo.tryParse(trimmed);
      if (info != null) return info;
    }
  }
  return null;
}
