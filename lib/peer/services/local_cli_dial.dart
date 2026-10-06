import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 与 [CliHost.hubRootFromEnv] 同一套目录。放在这里是为了拨号不必反向依赖
/// `CliHost`（那边已经引用了连接管理器）。
String cliHubRootFromEnv(Map<String, String> env, {p.Style? style}) {
  final ctx = p.Context(
    style: style ?? (Platform.isWindows ? p.Style.windows : p.Style.posix),
  );
  final explicit = env['SHEPAW_HUB_HOME'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return ctx.join(xdg, 'shepaw-hub');
  var home = '.';
  for (final key in const ['HOME', 'USERPROFILE']) {
    final value = env[key];
    if (value != null && value.isNotEmpty) {
      home = value;
      break;
    }
  }
  return ctx.join(home, '.config', 'shepaw-hub');
}

/// 指纹就是正在听的本机 CLI 时，拨这个回环地址。
///
/// 握手会把 CLI 广告的 VPN / 局域网地址学进来。切网之后那个地址不在当前
/// 子网，重连会跳过 LAN，又因为没有 Channel 端点一直等对方来连。CLI 只听
/// 在本机，必须走回环。
String? localCliLoopback({
  required String peerFingerprint,
  required String? cliFingerprint,
  required int? port,
}) {
  final want = (cliFingerprint ?? '').trim().toLowerCase();
  final got = peerFingerprint.trim().toLowerCase();
  if (want.isEmpty || got != want) return null;
  if (port == null || port <= 0) return null;
  return 'ws://127.0.0.1:$port/peer/ws';
}

/// 读 `peer-state.json`。进程不在了就当没有本机 CLI。
Future<({String fingerprint, int port})?> readRunningCliPeerState({
  File? stateFile,
  Future<bool> Function(int pid)? processAlive,
}) async {
  final file = stateFile ??
      File('${cliHubRootFromEnv(Platform.environment)}/peer-state.json');
  if (!file.existsSync()) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final version = (decoded['version'] as String?)?.trim() ?? '';
  final port = decoded['port'];
  final pid = decoded['pid'];
  final fingerprint = (decoded['fingerprint'] as String?)?.trim() ?? '';
  if (version.isEmpty || fingerprint.isEmpty) return null;
  if (port is! int || port <= 0) return null;
  if (pid is! int || pid <= 0) return null;
  final alive = processAlive ?? _processAlive;
  if (!await alive(pid)) return null;
  return (fingerprint: fingerprint, port: port);
}

/// 这台已配对设备和本机 CLI 是同一只时，返回应拨的回环地址。
Future<String?> localCliDialEndpoint(
  String peerFingerprint, {
  File? stateFile,
  Future<bool> Function(int pid)? processAlive,
}) async {
  final cli = await readRunningCliPeerState(
    stateFile: stateFile,
    processAlive: processAlive,
  );
  if (cli == null) return null;
  return localCliLoopback(
    peerFingerprint: peerFingerprint,
    cliFingerprint: cli.fingerprint,
    port: cli.port,
  );
}

Future<bool> _processAlive(int pid) async {
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
