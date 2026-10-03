import 'dart:convert';
import 'dart:io';

import '../peer/models/paired_peer.dart';
import '../peer/models/pairing_payload.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';

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
  static String hubRoot() {
    final env = Platform.environment;
    final explicit = env['SHEPAW_HUB_HOME'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final xdg = env['XDG_CONFIG_HOME'];
    final home = env['HOME'] ?? '';
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
    return '$base/shepaw-hub';
  }

  /// `peer-state.json` 带 `version`，而且里面的 pid 还活着，才算这台主机在跑。
  static Future<CliHostEndpoint?> detect() async {
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
    final fingerprint = cli.fingerprint.trim();
    if (fingerprint.isNotEmpty) {
      final existing =
          await PeerStorageService().getPeerByFingerprint(fingerprint);
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

  static Future<String?> resolveBinary() async {
    final env = Platform.environment['SHEPAW_BIN'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final home = Platform.environment['HOME'] ?? '';
    for (final path in [
      '$home/workspace/shepaw/shepaw-cli/target/debug/shepaw',
      '$home/workspace/shepaw/shepaw-cli/target/release/shepaw',
    ]) {
      if (File(path).existsSync()) return path;
    }
    final which = await Process.run('/usr/bin/which', ['shepaw']);
    final found = which.stdout.toString().trim();
    if (which.exitCode == 0 && found.isNotEmpty && File(found).existsSync()) {
      return found;
    }
    return null;
  }

  static Future<PeerPairingInfo> mintPairing(CliHostEndpoint host) async {
    final result = await Process.run(host.binary, [
      'pair',
      '--host',
      '127.0.0.1',
      '--port',
      '${host.port}',
      '--local',
      host.localEndpoint,
      '--name',
      '这台电脑',
    ]);
    if (result.exitCode != 0) {
      final detail = [
        result.stderr.toString().trim(),
        result.stdout.toString().trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      throw StateError(detail.isEmpty ? 'shepaw pair 失败' : detail);
    }
    String? qr;
    for (final line in result.stdout.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('shepaw://')) {
        qr = trimmed;
        break;
      }
    }
    final info = qr == null ? null : PeerPairingInfo.tryParse(qr);
    if (info == null) {
      throw StateError('shepaw pair 没有给出配对票据');
    }
    return info;
  }
}
