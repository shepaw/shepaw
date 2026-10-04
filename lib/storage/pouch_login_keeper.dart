import 'dart:async';

import '../peer/services/peer_connection_manager.dart';
import '../service_locator.dart';
import 'pouch_login.dart';
import 'pouch_login_client.dart';
import 'pouch_session.dart';

typedef PouchRelogin = Future<PouchLoginGrant> Function({
  required String hostPeerId,
  required String pouchId,
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
  });

  static final PouchLoginKeeper instance = PouchLoginKeeper.production();

  factory PouchLoginKeeper.production() {
    return PouchLoginKeeper(
      events: PeerConnectionManager.instance.controlEvents,
      readSession: PouchSessionStore.readActive,
      login: requestPouchLogin,
      persist: (session) async {
        await PouchSessionStore(await PouchSessionStore.appFile())
            .save(session);
      },
      install: PouchChannel.install,
      forgetSession: () async {
        await PouchSessionStore(await PouchSessionStore.appFile()).forget();
      },
      clearChannel: PouchChannel.clear,
      openChooser: () {
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/pouch',
          (_) => false,
        );
      },
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

  StreamSubscription<PeerControlEvent>? _sub;
  Future<void>? _inflight;
  final _relogged = StreamController<void>.broadcast();
  int _reloginGeneration = 0;

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

  void start() {
    _sub ??= events.listen(_onEvent);
  }

  void _onEvent(PeerControlEvent event) {
    if (event.type != 'pouch_login_required') return;
    if (_inflight != null) return;
    _inflight = _relogin(event).whenComplete(() => _inflight = null);
  }

  Future<void> _relogin(PeerControlEvent event) async {
    final session = await readSession();
    if (session == null || session.hostPeerId != event.peerId) return;
    if (session.pouchId.isEmpty) return;
    try {
      final grant = await login(
        hostPeerId: session.hostPeerId,
        pouchId: session.pouchId,
      );
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
      _reloginGeneration += 1;
      if (!_relogged.isClosed) _relogged.add(null);
    } catch (error) {
      if (!_pouchGone(error)) return;
      await forgetSession();
      clearChannel();
      openChooser();
    }
  }
}

bool _pouchGone(Object error) => error.toString().contains('没有这只袋子');
