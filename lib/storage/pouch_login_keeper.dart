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
/// 被拦下的那一帧不在这里重发，调用方按原来的超时和重试处理。
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
    } catch (error) {
      if (!_pouchGone(error)) return;
      await forgetSession();
      clearChannel();
      openChooser();
    }
  }
}

bool _pouchGone(Object error) => error.toString().contains('没有这只袋子');
