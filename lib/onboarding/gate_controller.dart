import 'dart:async';

import 'package:flutter/foundation.dart';

import '../peer/models/paired_peer.dart';
import '../peer/pairing_endpoints.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/cli_host.dart';
import '../services/logger_service.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_credential_store.dart';
import '../storage/pouch_session.dart';
import '../storage/pouch_grant.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_login_keeper.dart';
import 'credential_restore.dart';
import 'gate_errors.dart';
import 'gate_pouch.dart';
import 'widgets/gate_widgets.dart';

/// 解锁页要用的那些外部能力。全部注入，测试里换成假的。
class GateDeps {
  const GateDeps({
    required this.readSession,
    required this.lookupPeer,
    required this.listPouches,
    required this.login,
    required this.persist,
    required this.installChannel,
    required this.connect,
    required this.credentials,
    this.inviteLogin,
    this.connectedIds,
    this.restore,
    this.resolveLocalHost,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<PouchSession?> Function() readSession;
  final Future<PairedPeer?> Function(String hostPeerId) lookupPeer;

  /// 问主机上有哪些袋子。一台主机只有一只，取第一只。
  final Future<List<PouchDescriptor>> Function(String hostPeerId) listPouches;

  final Future<PouchLoginGrant> Function({
    required String hostPeerId,
    required String pouchId,
    required String password,
  }) login;

  /// 带加入码登录，不用密码。袋子 id 由主机按邀请记录给出。
  final Future<PouchLoginGrant> Function({
    required String hostPeerId,
    required String inviteId,
  })? inviteLogin;

  final Future<void> Function(PouchSession session) persist;
  final void Function(PouchSession session) installChannel;

  /// `redial` 为真时先断开再连，用来清掉息屏留下的半开连接。
  final Future<void> Function(PairedPeer peer, {required bool redial}) connect;

  final PouchCredentialStore? credentials;

  /// 连接状态变化的通知流。主机从离线变在线时自动续期。
  final Stream<Set<String>> Function()? connectedIds;

  /// 用设备凭据静默续期。没有登录态但连上了主机时试一次。
  final Future<RestoreResult> Function(String hostPeerId)? restore;

  /// 页面只知道「主机就是这台电脑」、还没有 peer id 时，认正在跑的本机 CLI。
  ///
  /// 退出登录会打开没有参数的解锁页。不认的话，后面的名单请求发到空地址，
  /// 干等 8 秒超时，人还没输密码就被说成「连不上主机」。
  final Future<PairedPeer?> Function()? resolveLocalHost;

  final void Function(String message)? log;
  final DateTime Function() _now;

  DateTime now() => _now();

  /// 接真实服务的那份。
  factory GateDeps.production() => GateDeps(
        readSession: PouchSessionStore.readActive,
        lookupPeer: (hostPeerId) =>
            PeerStorageService().getPeerById(hostPeerId),
        listPouches: (hostPeerId) => requestPouchList(hostPeerId: hostPeerId),
        login: ({
          required String hostPeerId,
          required String pouchId,
          required String password,
        }) =>
            requestPouchLogin(
          hostPeerId: hostPeerId,
          pouchId: pouchId,
          password: password,
        ),
        inviteLogin: ({
          required String hostPeerId,
          required String inviteId,
        }) =>
            requestPouchInviteLogin(
          hostPeerId: hostPeerId,
          inviteId: inviteId,
        ),
        persist: (session) async {
          await PouchSessionStore(await PouchSessionStore.appFile())
              .save(session);
        },
        installChannel: PouchChannel.install,
        connect: (peer, {required bool redial}) async {
          // 本机主机走 attach：顺手把地址收回环，旧端口一起修好。
          final cli = await CliHost.detect();
          if (cli != null && sameFingerprint(cli.fingerprint, peer.fingerprint)) {
            await CliHost.attach(cli);
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
        credentials: PouchCredentialStore.instance,
        connectedIds: () => PeerConnectionManager.instance.events
            .map((_) => PeerConnectionManager.instance.connectedPeerIds.toSet()),
        restore: (hostPeerId) async =>
            productionCredentialRestore().run(hostPeerId: hostPeerId),
        resolveLocalHost: () async {
          final cli = await CliHost.detect();
          if (cli == null) return null;
          try {
            return await CliHost.ensurePaired(cli);
          } catch (error) {
            LoggerService().warning(
              'local host resolve failed: $error',
              tag: 'Gate',
            );
            return null;
          }
        },
        log: (message) => LoggerService().info(message, tag: 'Gate'),
      );
}

/// 解锁页的状态。
///
/// 一机一袋：袋子不出现在界面上，这里按「会话 → 本机记住的 → 主机名单」推出来。
/// 逻辑从 `PhoneAuthScreen` / `PouchGateScreen` 搬过来，不要在那两个地方各留一份。
class GateController extends ChangeNotifier {
  GateController({required GateDeps deps}) : _deps = deps;

  final GateDeps _deps;

  String _hostPeerId = '';
  PairedPeer? _peer;
  PouchDescriptor? _pouch;
  HostReachability _reach = HostReachability.unknown;
  GateError? _error;
  DateTime? _lockedUntil;
  bool _busy = false;

  /// 主机上连一只袋子都没有。
  bool _noPouch = false;

  /// 欢迎语里那个名字。取不到就显示通用的「欢迎回来」。
  String _pouchName = '';

  int _shakeKey = 0;
  Timer? _tick;
  StreamSubscription<Set<String>>? _connectSub;
  bool _disposed = false;

  String get hostPeerId => _hostPeerId;
  PairedPeer? get peer => _peer;
  PouchDescriptor? get pouch => _pouch;
  HostReachability get reach => _reach;
  GateError? get error => _error;
  bool get busy => _busy;
  bool get noPouch => _noPouch;
  String get pouchName => _pouchName;
  int get shakeKey => _shakeKey;

  /// 锁定还剩多久。到点了自动恢复。
  Duration? get lockedFor {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(_deps.now());
    return left > Duration.zero ? left : null;
  }

  bool get locked => lockedFor != null;

  /// 主机是不是这台电脑。本机主机离线时给「重启主机」，远端给「重试」。
  bool thisComputer = false;

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _connectSub?.cancel();
    super.dispose();
  }

  void _emit() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 进页面：推出袋子，顺便探一下主机在不在。
  ///
  /// 还没有 peer id 时先认本机 CLI，再连上，最后才问袋子名单。
  /// 空地址直接去问，8 秒后只会超时，页面却把它画成「连不上主机」。
  Future<void> load(String hostPeerId) async {
    var id = hostPeerId.trim();
    if (id.isEmpty) {
      _setReach(HostReachability.connecting);
      final local = await _deps.resolveLocalHost?.call();
      if (_disposed) return;
      final resolved = local?.id.trim() ?? '';
      if (local != null && resolved.isNotEmpty) {
        id = resolved;
        _peer = local;
      }
    }
    _hostPeerId = id;
    if (_peer == null && id.isNotEmpty) {
      _peer = await _deps.lookupPeer(id);
      if (_disposed) return;
    }
    _pouch = id.isEmpty ? null : await _rememberedPouch(id);
    if (_disposed) return;
    _watchConnectivity();
    if (_peer != null) {
      unawaited(_connectThenProbe(id));
    } else if (id.isNotEmpty) {
      // 有 id、本地还没有配对记录。问不到也不锁住输入。
      unawaited(_probe(id));
    } else {
      _reach = HostReachability.offline;
    }
    _emit();
  }

  /// 主机会在后台自己重连。连上的时候把登录态接回来，不用用户再点一次。
  void _watchConnectivity() {
    final stream = _deps.connectedIds?.call();
    if (stream == null) return;
    _connectSub?.cancel();
    _connectSub = stream.listen((ids) {
      final online = ids.contains(_hostPeerId);
      if (!online) {
        if (_reach == HostReachability.online) {
          _setReach(HostReachability.offline);
        }
        return;
      }
      final wasOffline = _reach != HostReachability.online;
      _setReach(HostReachability.online);
      if (wasOffline) {
        _error = null;
        unawaited(_probe(_hostPeerId));
      }
      unawaited(_tryRestore());
    });
  }

  /// 有凭据的话，连上主机就静默续期。成功时 [restored] 会响一次。
  Future<void> _tryRestore() async {
    final restore = _deps.restore;
    if (restore == null || _restored) return;
    try {
      final restored = await restore(_hostPeerId) == RestoreResult.restored;
      if (_disposed || !restored) return;
      _restored = true;
      _emit();
    } catch (error) {
      _deps.log?.call('silent restore failed: $error');
    }
  }

  /// 静默续期成功。解锁页看到它就自己进主页。
  bool get restored => _restored;
  bool _restored = false;

  Future<PouchDescriptor?> _rememberedPouch(String hostPeerId) async {
    final session = await _deps.readSession();
    if (session != null && session.hostPeerId == hostPeerId) {
      _pouchName = session.pouchName;
      if (session.pouchId.isNotEmpty) {
        return PouchDescriptor(
          id: session.pouchId,
          name: session.pouchName,
          rootPath: '',
        );
      }
    }
    return null;
  }

  Future<void> _connectThenProbe(String hostPeerId) async {
    final peer = _peer;
    if (peer == null || _disposed) return;
    _setReach(HostReachability.connecting);
    try {
      await _deps.connect(peer, redial: false);
      if (_disposed) return;
      _setReach(HostReachability.online);
    } catch (_) {
      if (_disposed) return;
      _setReach(HostReachability.offline);
    }
    await _probe(hostPeerId);
  }

  /// 问主机要袋子名单。失败只把主机标成离线，不清掉已经推出来的袋子。
  ///
  /// 还没记住袋子时，把这次超时写进 [error]，给离线卡片的「详情」。
  /// 页面上不要再另起一行红字：卡片已经说明连不上了。
  Future<void> _probe(String hostPeerId) async {
    if (hostPeerId.trim().isEmpty || _disposed) return;
    try {
      final pouches = await _deps.listPouches(hostPeerId);
      if (_disposed) return;
      _noPouch = pouches.isEmpty;
      if (pouches.isNotEmpty) {
        _pouch = pouches.first;
        _pouchName = pouches.first.name;
      }
      _setReach(HostReachability.online);
    } catch (error) {
      if (_disposed) return;
      _deps.log?.call('pouch list failed: $error');
      if (_pouch == null) {
        _noPouch = false;
        _error = mapGateError(error);
      }
      _setReach(HostReachability.offline);
    }
    _emit();
  }

  void _setReach(HostReachability next) {
    if (_disposed || _reach == next) return;
    _reach = next;
    _emit();
  }

  Future<void> retryConnect() async {
    final peer = _peer;
    if (peer == null || _busy) return;
    _setReach(HostReachability.connecting);
    try {
      await _deps.connect(peer, redial: true);
      _setReach(HostReachability.online);
      _error = null;
      await _probe(_hostPeerId);
    } catch (error) {
      _setReach(HostReachability.offline);
      _error = mapGateError(error);
    }
    _emit();
  }

  /// 输密码进入。成功返回 true。
  Future<bool> submitPassword(String password) async {
    if (_busy || locked) return false;
    _busy = true;
    _error = null;
    _emit();
    try {
      var pouch = _pouch;
      pouch ??= await _resolvePouch();
      if (pouch == null) {
        _noPouch = true;
        return false;
      }
      _pouch = pouch;
      final grant = await _deps.login(
        hostPeerId: _hostPeerId,
        pouchId: pouch.id,
        password: password,
      );
      await _accept(pouch, grant);
      _clearLock();
      _error = null;
      return true;
    } catch (error) {
      _deps.log?.call('pouch login failed: $error');
      _error = mapGateError(error);
      if (_error!.kind == GateErrorKind.wrongPassword) {
        _shakeKey++;
      }
      _applyLock(_error!);
      return false;
    } finally {
      _busy = false;
      _emit();
    }
  }

  /// 用加入码进入：不用输密码。成功返回 true。
  ///
  /// 袋子 id 从回包里拿（请求是空着 pouch_id 发的），名字也是。
  Future<bool> redeemInvite(String inviteId) async {
    final inviteLogin = _deps.inviteLogin;
    if (inviteLogin == null || _busy || locked) return false;
    _busy = true;
    _error = null;
    _emit();
    try {
      final grant = await inviteLogin(
        hostPeerId: _hostPeerId,
        inviteId: inviteId,
      );
      final pouch = PouchDescriptor(
        id: grant.pouchId,
        name: grant.pouchName,
        rootPath: '',
      );
      _pouch = pouch;
      _pouchName = pouch.name;
      await _accept(pouch, grant);
      _clearLock();
      _error = null;
      return true;
    } catch (error) {
      _deps.log?.call('invite login failed: $error');
      _error = mapGateError(error);
      _applyLock(_error!);
      return false;
    } finally {
      _busy = false;
      _emit();
    }
  }

  /// 界面上不出现袋子，所以提交时才需要确认一次。
  Future<PouchDescriptor?> _resolvePouch() async {
    final pouches = await _deps.listPouches(_hostPeerId);
    if (pouches.isEmpty) return null;
    return pouches.first;
  }

  Future<void> _accept(PouchDescriptor pouch, PouchLoginGrant grant) async {
    final session = await _deps.readSession();
    final peer = _peer;
    final host = grant.pouchId.isEmpty ? pouch.id : grant.pouchId;
    final name = grant.pouchName.isEmpty ? pouch.name : grant.pouchName;
    final next = PouchSession(
      hubUrl: session?.hubUrl ?? (peer == null ? '' : hubUrlFor(peer)),
      pouchId: host,
      pouchName: name,
      hostPeerId: _hostPeerId,
      token: grant.token,
      sessionId: grant.sessionId,
      expiresAtMs: grant.expiresAtMs,
    );
    await applyLoginGrant(
      session: next,
      grant: grant,
      persist: _deps.persist,
      install: _deps.installChannel,
      saveCredential: ({
        required String hostPeerId,
        required String pouchId,
        required String credential,
        required int expiresAtMs,
      }) async {
        await _deps.credentials?.save(
          hostPeerId: hostPeerId,
          pouchId: pouchId,
          credential: credential,
          expiresAtMs: expiresAtMs,
        );
      },
    );
    // 手动登录不走 keeper 的重登成功分支，提示条要在这里收起来。
    PouchLoginKeeper.instance.clearPasswordRequired();
  }

  void _applyLock(GateError error) {
    final wait = error.retryAfter;
    if (wait == null) return;
    _lockedUntil = _deps.now().add(wait);
    _tick?.cancel();
    _tick = Timer(wait, () {
      _lockedUntil = null;
      _tick = null;
      _error = null;
      _emit();
    });
  }

  void _clearLock() {
    _lockedUntil = null;
    _tick?.cancel();
    _tick = null;
  }

  void clearError() {
    _error = null;
    _emit();
  }
}

/// 本机主机离线时用来重启。
Future<void> restartLocalHost() async {
  final cli = await CliHost.detect();
  final binary = cli?.binary ?? await CliHost.resolveBinary();
  if (binary == null) return;
  try {
    await CliHost.restart(binary);
  } catch (error) {
    LoggerService().error('shepaw restart failed', tag: 'Gate', error: error);
  }
}
