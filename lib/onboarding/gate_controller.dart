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
    _tick?.cancel();
    _connectSub?.cancel();
    super.dispose();
  }

  /// 进页面：推出袋子，顺便探一下主机在不在。
  Future<void> load(String hostPeerId) async {
    _hostPeerId = hostPeerId;
    _peer = await _deps.lookupPeer(hostPeerId);
    _pouch = await _rememberedPouch(hostPeerId);
    _watchConnectivity();
    if (_pouch == null) {
      // 本机没记住就问主机。问不到也不锁住输入，用户可以先输着。
      unawaited(_probe(hostPeerId));
    } else {
      unawaited(_connectThenProbe(hostPeerId));
    }
    notifyListeners();
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
      if (await restore(_hostPeerId) == RestoreResult.restored) {
        _restored = true;
        notifyListeners();
      }
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
    if (peer == null) return;
    _setReach(HostReachability.connecting);
    try {
      await _deps.connect(peer, redial: false);
      _setReach(HostReachability.online);
    } catch (_) {
      _setReach(HostReachability.offline);
    }
    await _probe(hostPeerId);
  }

  /// 问主机要袋子名单。失败只提示，不清掉已经推出来的袋子。
  Future<void> _probe(String hostPeerId) async {
    try {
      final pouches = await _deps.listPouches(hostPeerId);
      _noPouch = pouches.isEmpty;
      if (pouches.isNotEmpty) {
        _pouch = pouches.first;
        _pouchName = pouches.first.name;
      }
      _setReach(HostReachability.online);
    } catch (error) {
      _deps.log?.call('pouch list failed: $error');
      if (_pouch == null) {
        _noPouch = false;
        _error = mapGateError(error);
      }
      _setReach(HostReachability.offline);
    }
    notifyListeners();
  }

  void _setReach(HostReachability next) {
    if (_reach == next) return;
    _reach = next;
    notifyListeners();
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
    notifyListeners();
  }

  /// 输密码进入。成功返回 true。
  Future<bool> submitPassword(String password) async {
    if (_busy || locked) return false;
    _busy = true;
    _error = null;
    notifyListeners();
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
      notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
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
      notifyListeners();
    });
  }

  void _clearLock() {
    _lockedUntil = null;
    _tick?.cancel();
    _tick = null;
  }

  void clearError() {
    _error = null;
    notifyListeners();
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
