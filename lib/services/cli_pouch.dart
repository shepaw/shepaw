import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/host_entry.dart';
import '../peer/services/peer_connection_manager.dart';
import '../storage/pouch_credential_store.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';
import 'cli_host.dart';
import 'cli_language.dart';
import 'logger_service.dart';

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

/// 最近用过的在列表里就选它，否则选第一只。
CliPouchAccount? defaultPouchAccount(
  List<CliPouchAccount> accounts, {
  String? recentId,
}) {
  if (accounts.isEmpty) return null;
  final recent = recentId?.trim() ?? '';
  if (recent.isNotEmpty) {
    for (final account in accounts) {
      if (account.id == recent) return account;
    }
  }
  return accounts.first;
}

CliPouchAccount? _pouchAccountFromMap(Map decoded) {
  final id = (decoded['id'] as String?)?.trim() ?? '';
  final name = (decoded['name'] as String?)?.trim() ?? '';
  if (id.isEmpty || name.isEmpty) return null;
  return CliPouchAccount(id: id, name: name);
}

CliPouchAccount? parsePouchAccount(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) continue;
      final account = _pouchAccountFromMap(decoded);
      if (account != null) return account;
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

/// 严格版 `account list` 解析：认不出输出时返回 null，而不是空名单。
///
/// 兜底判定要靠它区分「这只主机真的没有袋子」和「CLI 输出不认识」（旧版 /
/// 坏掉的 shepaw 会打印别的东西）。把后者当成空名单会把一台已有袋子和数据的
/// 主机送去重新初始化，形成 create-password 死循环。
List<CliPouchAccount>? parsePouchAccountListOrNull(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List) continue;
      return decoded
          .whereType<Map>()
          .map(_pouchAccountFromMap)
          .whereType<CliPouchAccount>()
          .toList();
    } catch (_) {}
  }
  return null;
}

/// `shepaw init` 在 Hub 还没起来时只把袋子建好、不签登录态，回这一行。
///
/// 调用方看到它就知道还要自己拉起 Hub 再登录，别把它当 grant 解析。
CliPouchAccount? parseOfflineInit(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map || decoded['offline'] != true) continue;
      return _pouchAccountFromMap(decoded);
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// `shepaw password status` 的输出。认不出时返回 null。
bool? parsePasswordStatus(String stdout) {
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    switch (line.trim()) {
      case 'set':
        return true;
      case 'unset':
      // 主机把「口令文件丢了 / 写坏了」单独报出来，但这两种状态在 App 侧
      // 都还是要走「重新初始化」这条恢复出口，不能掉进「认不出 → null」的
      // 兜底里被当成探测失败。
      case 'missing':
      case 'corrupt':
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
    this.credential,
    this.credentialExpiresAtMs = 0,
  });

  final String id;
  final String name;
  final String token;
  final String sid;
  final int expiresAtMs;

  /// 本机通道登录顺手签发的设备凭据。老版本 `shepaw` 不会带。
  final String? credential;
  final int credentialExpiresAtMs;
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
      final credential = (decoded['credential'] as String?)?.trim() ?? '';
      final credentialExpires = decoded['credential_expires_at'];
      return CliLoginGrant(
        id: id,
        name: name,
        token: token,
        sid: sid,
        expiresAtMs: expires,
        credential: credential.isEmpty ? null : credential,
        credentialExpiresAtMs:
            credentialExpires is int && credentialExpires > 0
                ? credentialExpires
                : 0,
      );
    } catch (_) {}
  }
  return null;
}

/// 上次进入的储物袋。登录 token 被清掉之后，名称还在，重启不用重新创建。
class PouchLoginMemory {
  static const idKey = 'pouch_login_id';
  static const nameKey = 'pouch_login_name';

  static Future<void> write({required String id, required String name}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(idKey, id);
    await prefs.setString(nameKey, name);
  }

  static Future<({String id, String name})?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(idKey)?.trim() ?? '';
    final name = prefs.getString(nameKey)?.trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return (id: id, name: name);
  }
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
  static const _statusTimeout = Duration(seconds: 10);
  static const _listTimeout = Duration(seconds: 8);
  static const _commandTimeout = Duration(seconds: 15);
  // 离线建袋子要跑一次 PBKDF2，冷启动的 CLI 也比常驻命令慢一点。
  static const _initTimeout = Duration(seconds: 30);

  static Future<bool> passwordIsSet(String binary) async {
    final result = await _run(
      binary,
      const ['password', 'status'],
      timeout: _statusTimeout,
    );
    final parsed = parsePasswordStatus(result);
    if (parsed == null) {
      // 认不出输出时不能猜成「没设过密码」：9.5 行会据此建袋子、重设口令。
      // 抛出去让调用方记 null，交给决策表走「准备主机」。
      throw StateError('认不出 shepaw password status 的输出：$result');
    }
    return parsed;
  }

  static Future<CliLoginGrant> init({
    required String binary,
    required String name,
    required String password,
    required String fingerprint,
  }) async {
    // 新电脑上 Hub 还起不来（Router::open 要 active_pouch），所以**不能**先
    // _ensureHub：那正是首次流程卡在「准备主机」的原因。让 `shepaw init`
    // 把袋子和口令离线落盘，再自己拉起 Hub、登录拿登录态。
    final result = await _run(
      binary,
      ['init', '--name', name, '--fingerprint', fingerprint],
      stdin: password,
      timeout: _initTimeout,
    );
    final grant = parseLoginGrant(result);
    if (grant != null) return grant; // Hub 本来就在跑：host_init 直接签了登录态。
    final offline = parseOfflineInit(result);
    if (offline == null) throw StateError('shepaw init 没有返回登录态');
    // 离线回执已经把 active_pouch 落盘，Hub 这时才起得来。login() 内部会先
    // _ensureHub，cli-addr 由主机侧等齐后再发帧，这里不用再探测一次；冷启动
    // 的登录也沿用 init 的宽松超时，别在 15 秒的默认预算里被杀掉。
    return login(
      binary: binary,
      name: offline.name,
      password: password,
      fingerprint: fingerprint,
      savedId: offline.id,
      timeout: _initTimeout,
    );
  }

  static Future<CliLoginGrant> login({
    required String binary,
    required String name,
    required String password,
    required String fingerprint,
    String? savedId,
    Duration timeout = _commandTimeout,
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
    final result = await _run(binary, args, stdin: password, timeout: timeout);
    final grant = parseLoginGrant(result);
    if (grant == null) throw StateError('shepaw login 没有返回登录态');
    return grant;
  }

  static Future<List<CliPouchAccount>> list(String binary) async {
    final result = await _run(
      binary,
      const ['account', 'list'],
      timeout: _listTimeout,
    );
    return parsePouchAccountList(result);
  }

  /// 兜底专用：只有确认读到一份能解析的名单，才回答「有没有袋子」。
  /// 认不出输出就抛错，由调用方保持 `null`，别把旧 CLI 的杂输出当成新电脑。
  static Future<bool> hasNoPouch(String binary) async {
    final result = await _run(
      binary,
      const ['account', 'list'],
      timeout: _listTimeout,
    );
    final accounts = parsePouchAccountListOrNull(result);
    if (accounts == null) {
      throw StateError('认不出 shepaw account list 的输出：$result');
    }
    return accounts.isEmpty;
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
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    final connected = PeerConnectionManager.instance.connectedPeerIds;
    if (!connected.contains(peer.id)) {
      // connectToPeer 内部最多能等 25 秒。登录页不能被它拖住，超过预算就
      // 交给后面的轮询；连接尝试本身还会在后台继续。
      try {
        await PeerConnectionManager.instance
            .connectToPeer(peer, ignoreTieBreak: true)
            .timeout(deadline.difference(DateTime.now()));
      } on TimeoutException {
        // 后台重连可能马上就好，下面再轮询一次。
      }
    }
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
    await PouchLoginMemory.write(id: grant.id, name: grant.name);
    PouchChannel.install(session);
    PouchLoginKeeper.instance.clearPasswordRequired();
    final credential = grant.credential ?? '';
    if (credential.isNotEmpty) {
      await PouchCredentialStore.instance.save(
        hostPeerId: peer.id,
        pouchId: grant.id,
        credential: credential,
        expiresAtMs: grant.credentialExpiresAtMs,
      );
      LoggerService().info(
        '设备凭据已保存：host=${peer.id} pouch=${grant.id}',
        tag: 'CliPouch',
      );
    }
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
    Duration timeout = _commandTimeout,
  }) async {
    final process = await Process.start(binary, shepawArgs(args));
    if (stdin != null) {
      process.stdin.write('$stdin\n');
    }
    await process.stdin.close();
    final outFuture = process.stdout.transform(utf8.decoder).join();
    final errFuture = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill();
        return -1;
      },
    );
    if (timedOut) {
      // 进程已经被杀掉。输出管道可能被它的子进程占着，不能在这里再等。
      unawaited(outFuture.catchError((_) => ''));
      unawaited(errFuture.catchError((_) => ''));
      throw TimeoutException(
        'shepaw 没有在 ${timeout.inSeconds} 秒内返回',
        timeout,
      );
    }
    final stderr = await errFuture;
    if (code != 0) throw StateError(cliFailureText(stderr));
    return outFuture;
  }
}
