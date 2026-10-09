import 'dart:convert';
import 'dart:io';

import '../onboarding/host_entry.dart';
import '../peer/services/peer_connection_manager.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_session.dart';
import 'cli_host.dart';

/// 储物袋账号。`name` 只给人看，`id` 才是身份。
class CliPouchAccount {
  const CliPouchAccount({required this.id, required this.name});

  final String id;
  final String name;
}

enum PouchPick { found, missing, ambiguous }

class PouchPickResult {
  const PouchPickResult(this.kind, {this.account});

  final PouchPick kind;
  final CliPouchAccount? account;
}

/// 名字对上一只就用它。同名多只时，只有和上次进入的 ID 一致才选中。
PouchPickResult pickPouchAccount({
  required String typedName,
  required List<CliPouchAccount> accounts,
  String? savedId,
}) {
  final name = typedName.trim();
  final matches = accounts.where((account) => account.name == name).toList();
  if (matches.length == 1) {
    return PouchPickResult(PouchPick.found, account: matches.single);
  }
  if (matches.length > 1) {
    final saved = savedId?.trim() ?? '';
    for (final account in matches) {
      if (saved.isNotEmpty && account.id == saved) {
        return PouchPickResult(PouchPick.found, account: account);
      }
    }
    return const PouchPickResult(PouchPick.ambiguous);
  }
  return const PouchPickResult(PouchPick.missing);
}

CliPouchAccount? parsePouchAccount(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) continue;
      final id = (decoded['id'] as String?)?.trim() ?? '';
      final name = (decoded['name'] as String?)?.trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      return CliPouchAccount(id: id, name: name);
    } catch (_) {}
  }
  return null;
}

List<CliPouchAccount> parsePouchAccountList(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List) continue;
      return decoded
          .whereType<Map>()
          .map((raw) {
            final id = (raw['id'] as String?)?.trim() ?? '';
            final name = (raw['name'] as String?)?.trim() ?? '';
            if (id.isEmpty || name.isEmpty) return null;
            return CliPouchAccount(id: id, name: name);
          })
          .whereType<CliPouchAccount>()
          .toList();
    } catch (_) {}
  }
  return const [];
}

/// `shepaw password status` 的输出。认不出时返回 null。
bool? parsePasswordStatus(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    switch (line.trim()) {
      case 'set':
        return true;
      case 'unset':
        return false;
    }
  }
  return null;
}

/// 本机 `shepaw login` / `shepaw init` 签发的登录态。
class CliLoginGrant {
  const CliLoginGrant({
    required this.id,
    required this.name,
    required this.token,
    required this.sid,
    required this.expiresAtMs,
  });

  final String id;
  final String name;
  final String token;
  final String sid;
  final int expiresAtMs;
}

CliLoginGrant? parseLoginGrant(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) continue;
      final id = (decoded['id'] as String?)?.trim() ?? '';
      final name = (decoded['name'] as String?)?.trim() ?? '';
      final token = (decoded['token'] as String?)?.trim() ?? '';
      final sid = (decoded['sid'] as String?)?.trim() ?? '';
      final expires = decoded['expires_at'];
      if (id.isEmpty || name.isEmpty || token.isEmpty || sid.isEmpty) continue;
      if (expires is! int || expires <= 0) continue;
      return CliLoginGrant(
        id: id,
        name: name,
        token: token,
        sid: sid,
        expiresAtMs: expires,
      );
    } catch (_) {}
  }
  return null;
}

String cliFailureText(String stderr) {
  final lines = stderr
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.contains('command failed'))
      .toList();
  if (lines.isEmpty) return 'shepaw 没有完成';
  return lines.last;
}

/// 本机储物袋的初始化都走 `shepaw`。Linux 上单独装的 CLI 用同一组命令。
class CliPouch {
  static Future<bool> passwordIsSet(String binary) async {
    final result = await _run(binary, const ['password', 'status']);
    return parsePasswordStatus(result) ?? false;
  }

  static Future<CliLoginGrant> init({
    required String binary,
    required String name,
    required String password,
    required String fingerprint,
  }) async {
    await _ensureHub(binary);
    final result = await _run(
      binary,
      ['init', '--name', name, '--fingerprint', fingerprint],
      stdin: password,
    );
    final grant = parseLoginGrant(result);
    if (grant == null) throw StateError('shepaw init 没有返回登录态');
    return grant;
  }

  static Future<CliLoginGrant> login({
    required String binary,
    required String name,
    required String password,
    required String fingerprint,
    String? savedId,
  }) async {
    await _ensureHub(binary);
    final args = <String>[
      'login',
      '--name',
      name,
      '--fingerprint',
      fingerprint,
      if (savedId != null && savedId.trim().isNotEmpty) ...[
        '--id',
        savedId.trim(),
      ],
    ];
    final result = await _run(binary, args, stdin: password);
    final grant = parseLoginGrant(result);
    if (grant == null) throw StateError('shepaw login 没有返回登录态');
    return grant;
  }

  static Future<List<CliPouchAccount>> list(String binary) async {
    final result = await _run(binary, const ['account', 'list']);
    return parsePouchAccountList(result);
  }

  /// 用本机通道签发的登录态连上 Hub。密码不再送进 peer 端口。
  static Future<void> openLocal(CliLoginGrant grant) async {
    await HostModeStore.write(HostMode.thisComputer);
    final binary = await CliHost.resolveBinary();
    if (binary == null) throw StateError('没有找到 shepaw');
    await _ensureHub(binary);
    final cli = await CliHost.detect();
    if (cli == null) throw StateError('shepaw 没有在时限内就绪');
    final peer = await CliHost.ensurePaired(cli);
    final connected = PeerConnectionManager.instance.connectedPeerIds;
    if (!connected.contains(peer.id)) {
      await PeerConnectionManager.instance.connectToPeer(
        peer,
        ignoreTieBreak: true,
      );
    }
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (PeerConnectionManager.instance.connectedPeerIds.contains(peer.id)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peer.id)) {
      throw StateError('还没连上 shepaw');
    }
    final session = PouchSession(
      hubUrl: cli.localEndpoint,
      pouchId: grant.id,
      pouchName: grant.name,
      hostPeerId: peer.id,
      token: grant.token,
      sessionId: grant.sid,
      expiresAtMs: grant.expiresAtMs,
    );
    await PouchSessionStore(await PouchSessionStore.appFile()).save(session);
    PouchChannel.install(session);
  }

  static Future<void> _ensureHub(String binary) async {
    if (await CliHost.detect() == null) {
      await CliHost.start(binary);
    }
  }

  static Future<String> _run(
    String binary,
    List<String> args, {
    String? stdin,
  }) async {
    final process = await Process.start(binary, args);
    if (stdin != null) {
      process.stdin.write('$stdin\n');
    }
    await process.stdin.close();
    final outFuture = process.stdout.transform(utf8.decoder).join();
    final errFuture = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    final stderr = await errFuture;
    if (code != 0) throw StateError(cliFailureText(stderr));
    return outFuture;
  }
}
