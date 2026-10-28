import 'dart:async';

import 'package:flutter/foundation.dart';

import '../peer/services/peer_connection_manager.dart';
import '../service_locator.dart';
import '../services/logger_service.dart';
import '../utils/platform_utils.dart';
import 'pouch_credential_store.dart';
import 'pouch_login.dart';
import 'pouch_login_client.dart';
import 'pouch_session.dart';

typedef PouchRelogin = Future<PouchLoginGrant> Function({
  required String hostPeerId,
  required String pouchId,
  String? credential,
});

/// 主机重启后登录态只活在内存里。收到 `pouch_login_required` 时用同一只袋子再登一次。
///
/// 被拦下的那一帧不在这里重发。重新登录成功后 [relogged] 响一次，调用方重发自己的请求。
class PouchLoginKeeper {
  PouchLoginKeeper({
    required this.events,
    required this.readSession,
    required this.login,
    required this.persist,
    required this.install,
    required this.forgetSession,
    required this.clearChannel,
    required this.openChooser,
    this.credentials,
    this.log,
  });

  static final PouchLoginKeeper instance = PouchLoginKeeper.production();

  factory PouchLoginKeeper.production() {
    return PouchLoginKeeper(
      events: PeerConnectionManager.instance.controlEvents,
      readSession: PouchSessionStore.readActive,
      login:
          ({required hostPeerId, required pouchId, String? credential}) =>
              requestPouchLogin(
        hostPeerId: hostPeerId,
        pouchId: pouchId,
        credential: credential,
      ),
      persist: (session) async {
        await PouchSessionStore(await PouchSessionStore.appFile())
            .save(session);
      },
      install: PouchChannel.install,
      forgetSession: () async {
        await PouchSessionStore(await PouchSessionStore.appFile()).forget();
      },
      clearChannel: PouchChannel.clear,
      credentials: PouchCredentialStore.instance,
      openChooser: () {
        final route = isDesktopPlatform ? '/pouch' : '/phone-login';
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          route,
          (_) => false,
        );
      },
      log: (message) =>
          LoggerService().info(message, tag: 'PouchLoginKeeper'),
    );
  }

  final Stream<PeerControlEvent> events;
  final Future<PouchSession?> Function() readSession;
  final PouchRelogin login;
  final Future<void> Function(PouchSession session) persist;
  final void Function(PouchSession session) install;
  final Future<void> Function() forgetSession;
  final void Function() clearChannel;
  final void Function() openChooser;

  /// 本机保存的设备凭据。为空表示这个环境不支持免密恢复（测试里不传即可）。
  final PouchCredentialStore? credentials;

  /// 重登过程的诊断日志。主机日志是 INFO 级且不含 App 侧因果链，这条链路
  /// 走坏时用户只看到「没有回复」，不写日志根本查不下去。
  final void Function(String message)? log;

  StreamSubscription<PeerControlEvent>? _sub;
  Future<void>? _inflight;
  final _relogged = StreamController<void>.broadcast();
  int _reloginGeneration = 0;

  /// 主机已经明确要密码。用户重新登录成功之前不再自动重试，否则每一帧被
  /// 拒都会再打一次密码接口，很快把主机的试错额度烧光。
  bool _needsUserPassword = false;

  /// 连续失败次数，用来退避。网络抖动时不要每 10 秒撞一次主机。
  int _failureCount = 0;
  DateTime? _retryNotBefore;

  static const _retryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// 主机要求输密码、自动恢复已经走不通了。登录页之外的地方（聊天页顶部
  /// 提示条）靠它告诉用户「不是没有回复，是要你重新登录」。
  final ValueNotifier<bool> _passwordRequired = ValueNotifier<bool>(false);

  ValueListenable<bool> get passwordRequired => _passwordRequired;

  /// 登录页（选主机 / 选袋子 / 输密码）还在树上的层数。
  ///
  /// 主机再要密码时如果把当前页 `pushNamedAndRemoveUntil` 掉，新页面一连上
  /// 又会收到 `pouch_login_required`，再推一次。页面和密码框就这样死循环。
  int _gateDepth = 0;

  /// 重新登录成功。不缓冲，错过的一方用 [reloginGeneration] 判断。
  Stream<void> get relogged => _relogged.stream;

  /// 成功重登的次数。用来避免在监听 [relogged] 之前就错过事件。
  int get reloginGeneration => _reloginGeneration;

  /// 等到一次比 [seenGeneration] 更新的重登，最多 8 秒。
  Future<void> waitForRelogin({
    required int seenGeneration,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_reloginGeneration > seenGeneration) return;
    final done = Completer<void>();
    final sub = _relogged.stream.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      if (_reloginGeneration > seenGeneration) return;
      await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  /// 登录页 `initState` 调用。和 [releaseGate] 成对。
  void retainGate() {
    _gateDepth += 1;
  }

  /// 登录页 `dispose` 调用。
  void releaseGate() {
    if (_gateDepth > 0) _gateDepth -= 1;
  }

  void _requestChooser() {
    if (_gateDepth > 0) return;
    openChooser();
  }

  /// 提示条上的「去登录」。
  void requestSignIn() => _requestChooser();

  /// 密码登录成功了（登录页 / 手机认证页），提示条该收起来。
  void clearPasswordRequired() {
    _needsUserPassword = false;
    _failureCount = 0;
    _retryNotBefore = null;
    _passwordRequired.value = false;
  }

  void start() {
    _sub ??= events.listen(_onEvent);
  }

  void _onEvent(PeerControlEvent event) {
    if (event.type != 'pouch_login_required') return;
    // 已经让用户去输密码了。再自动试只会继续失败，还会触发主机限流。
    if (_needsUserPassword) return;
    final notBefore = _retryNotBefore;
    if (notBefore != null && DateTime.now().isBefore(notBefore)) return;
    if (_inflight != null) return;
    _inflight = _relogin(event).whenComplete(() => _inflight = null);
  }

  Future<void> _relogin(PeerControlEvent event) async {
    final session = await readSession();
    if (session == null || session.hostPeerId != event.peerId) {
      log?.call('主机 ${event.peerId} 要求重新登录，但本地登录态对不上，跳过');
      return;
    }
    if (session.pouchId.isEmpty) return;
    final credential = await _readCredential(session);
    final byCredential = (credential ?? '').isNotEmpty;
    log?.call(
      '主机要求重新登录：pouch=${session.pouchId}'
      '${byCredential ? '（设备凭据）' : ''}',
    );
    try {
      final grant = await login(
        hostPeerId: session.hostPeerId,
        pouchId: session.pouchId,
        credential: credential,
      );
      await _acceptGrant(session, grant);
    } on PouchCredentialRejected catch (error) {
      // 凭据过期、改过密码、解除过配对。删掉本机这张，用内存里的密码再试一次；
      // 没有密码就走登录页（host 回 password_required）。
      log?.call('设备凭据被拒绝：pouch=${session.pouchId} error=$error');
      await _dropCredential(session);
      try {
        final grant = await login(
          hostPeerId: session.hostPeerId,
          pouchId: session.pouchId,
        );
        await _acceptGrant(session, grant);
      } catch (retryError) {
        log?.call('重新登录失败：pouch=${session.pouchId} error=$retryError');
        await _handleFailure(session, retryError);
      }
    } catch (error) {
      log?.call('重新登录失败：pouch=${session.pouchId} error=$error');
      await _handleFailure(session, error);
    }
  }

  Future<void> _acceptGrant(PouchSession session, PouchLoginGrant grant) async {
    final next = PouchSession(
      hubUrl: session.hubUrl,
      pouchId: session.pouchId,
      pouchName: session.pouchName,
      hostPeerId: session.hostPeerId,
      token: grant.token,
      sessionId: grant.sessionId,
      expiresAtMs: grant.expiresAtMs,
    );
    await persist(next);
    install(next);
    // 密码登录会换发新凭据；凭据登录不轮换，这里就没有新值。
    final issued = grant.credential?.trim() ?? '';
    if (issued.isNotEmpty) {
      await _saveCredential(session, issued, grant.credentialExpiresAtMs);
    }
    _reloginGeneration += 1;
    _needsUserPassword = false;
    _failureCount = 0;
    _retryNotBefore = null;
    _passwordRequired.value = false;
    log?.call('重新登录成功：pouch=${session.pouchId}');
    if (!_relogged.isClosed) _relogged.add(null);
  }

  Future<void> _handleFailure(PouchSession session, Object error) async {
    // 主机不认这只袋子（主机重建过、活动袋子换成了别的）。本地那张还没
    // 过期的登录是废的：留着它，重新装回来的每一帧依旧会被主机丢掉，
    // 界面一片空白，也没人去登录页 —— 用户只看到「没有回复」。所以这里
    // 必须先认「袋子没了」，再看登录是否过期。
    if (_pouchGone(error)) {
      await forgetSession();
      await _dropCredential(session);
      clearChannel();
      _needsUserPassword = false;
      _failureCount = 0;
      _retryNotBefore = null;
      _passwordRequired.value = false;
      _requestChooser();
      return;
    }
    // 主机重启后不认磁盘上那张还没过期的登录。沿用它的话，模型名单这类
    // 密封请求会被丢掉，界面一直是空的。要密码就回登录页，同时让顶部的
    // 提示条说明原因。
    if (error is PouchPasswordRequired) {
      log?.call('需要重新输入主机密码：pouch=${session.pouchId}，转到登录页');
      clearChannel();
      _needsUserPassword = true;
      _failureCount = 0;
      _retryNotBefore = null;
      _passwordRequired.value = true;
      _requestChooser();
      return;
    }
    _scheduleRetry();
    final existing = await readSession();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing != null && existing.isLoggedIn(now)) {
      install(existing);
    }
  }

  void _scheduleRetry() {
    _failureCount = _failureCount >= _retryDelays.length
        ? _retryDelays.length
        : _failureCount + 1;
    final delay = _retryDelays[_failureCount - 1];
    _retryNotBefore = DateTime.now().add(delay);
    log?.call('重新登录失败，${delay.inSeconds} 秒后再试');
  }

  Future<String?> _readCredential(PouchSession session) async {
    final store = credentials;
    if (store == null) return null;
    final saved = await store.read(session.hostPeerId);
    if (saved == null || saved.pouchId != session.pouchId) return null;
    if (saved.isExpired(DateTime.now().millisecondsSinceEpoch)) {
      log?.call('设备凭据已过期：pouch=${session.pouchId}');
      return null;
    }
    return saved.credential;
  }

  Future<void> _saveCredential(
    PouchSession session,
    String credential,
    int expiresAtMs,
  ) async {
    final store = credentials;
    if (store == null) return;
    await store.save(
      hostPeerId: session.hostPeerId,
      pouchId: session.pouchId,
      credential: credential,
      expiresAtMs: expiresAtMs,
    );
  }

  Future<void> _dropCredential(PouchSession session) async {
    final store = credentials;
    if (store == null) return;
    await store.delete(session.hostPeerId);
  }
}

bool _pouchGone(Object error) => error.toString().contains('没有这只袋子');
