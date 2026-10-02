import 'dart:convert';
import 'dart:io';

import '../peer/models/pairing_payload.dart';

/// 本机 `shepaw` CLI 正在听的主机。电脑上的 App 用它配对，不再走旧的仪表盘。
class CliHostEndpoint {
  const CliHostEndpoint({required this.port, required this.binary});

  final int port;
  final String binary;

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

  /// `peer-state.json` 带 `version` 时，是这次 CLI 写下的主机。
  static Future<CliHostEndpoint?> detect() async {
    final file = File('${hubRoot()}/peer-state.json');
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final version = (decoded['version'] as String?)?.trim() ?? '';
    final port = decoded['port'];
    if (version.isEmpty || port is! int || port <= 0) return null;
    final binary = await resolveBinary();
    if (binary == null) return null;
    return CliHostEndpoint(port: port, binary: binary);
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
