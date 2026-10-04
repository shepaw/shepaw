import 'dart:async';

import '../models/agent.dart';
import '../peer/models/paired_peer.dart';
import '../peer/pairing_endpoints.dart';
import '../peer/pouch_pair.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import 'cli_host.dart';
import 'local_api_service.dart';
import 'remote_agent_service.dart';
import 'she_service.dart';
import '../storage/device_identity.dart';
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';
import '../service_locator.dart';

/// 通讯录里的一台设备，以及挂在它名下的智能体。
class ContactDevice {
  const ContactDevice({
    required this.peer,
    required this.agents,
    required this.isThisDevice,
    required this.online,
  });

  final PairedPeer peer;
  final List<Agent> agents;
  final bool isThisDevice;
  final bool online;
}

/// 通讯录三节：主机、工作设备、我的设备。群聊不在这里。
class ContactsView {
  const ContactsView({
    required this.hasSession,
    required this.host,
    required this.hostAgents,
    required this.otherAgents,
    required this.workers,
    required this.myDevices,
    required this.hostOnline,
    required this.hostIsThisComputer,
    required this.rosterFailed,
  });

  final bool hasSession;
  final PairedPeer? host;
  final List<Agent> hostAgents;
  final List<Agent> otherAgents;
  final List<ContactDevice> workers;
  final List<ContactDevice> myDevices;
  final bool hostOnline;
  final bool hostIsThisComputer;
  final bool rosterFailed;

  static const empty = ContactsView(
    hasSession: false,
    host: null,
    hostAgents: <Agent>[],
    otherAgents: <Agent>[],
    workers: <ContactDevice>[],
    myDevices: <ContactDevice>[],
    hostOnline: false,
    hostIsThisComputer: false,
    rosterFailed: false,
  );
}

/// 把登录态、本机主机行、主机名单和智能体合成一份通讯录。
///
/// 主机名单里的 id 和本机配对行不是同一套，所以智能体只按
/// `roster_hub_fingerprint` 往工作设备上挂。
ContactsView buildContacts({
  required String? hostPeerId,
  required PairedPeer? hostPeer,
  required List<PairedPeer> roster,
  required List<Agent> agents,
  required String? appFingerprint,
  required String? localCliFingerprint,
  required Set<String> connectedPeerIds,
  required bool rosterFailed,
}) {
  final hostId = hostPeerId?.trim() ?? '';
  if (hostId.isEmpty) return ContactsView.empty;

  final hostOnline = connectedPeerIds.contains(hostId);
  final filteredRoster = <PairedPeer>[
    for (final peer in roster)
      if (!sameFingerprint(peer.fingerprint, hostPeer?.fingerprint)) peer,
  ];
  final rosterFingerprints = <String>{
    for (final peer in filteredRoster) peer.fingerprint.trim().toLowerCase(),
  };

  final hostAgents = <Agent>[];
  final pending = <Agent>[];
  for (final agent in agents) {
    if (!agent.isPeerAgent || agent.hiddenOnThisApp) continue;
    if (agent.sourcePeerId == hostId) {
      hostAgents.add(agent);
    } else {
      pending.add(agent);
    }
  }
  hostAgents.sort((a, b) {
    final rankA = SheService.isSheIdentity(a.id, a.metadata) ? 0 : 1;
    final rankB = SheService.isSheIdentity(b.id, b.metadata) ? 0 : 1;
    return rankA.compareTo(rankB);
  });

  final byFingerprint = <String, List<Agent>>{};
  final otherAgents = <Agent>[];
  for (final agent in pending) {
    final fingerprint = _rosterFingerprint(agent);
    if (fingerprint != null && rosterFingerprints.contains(fingerprint)) {
      byFingerprint.putIfAbsent(fingerprint, () => <Agent>[]).add(agent);
    } else {
      otherAgents.add(agent);
    }
  }

  final workers = <ContactDevice>[];
  final myDevices = <ContactDevice>[];
  for (final peer in filteredRoster) {
    final hanging =
        byFingerprint[peer.fingerprint.trim().toLowerCase()] ?? const <Agent>[];
    final device = ContactDevice(
      peer: peer,
      agents: hanging,
      isThisDevice: sameFingerprint(peer.fingerprint, appFingerprint),
      online: peer.state == PeerConnectionState.connected,
    );
    if (hanging.isNotEmpty) {
      workers.add(device);
    } else {
      myDevices.add(device);
    }
  }

  return ContactsView(
    hasSession: true,
    host: hostPeer,
    hostAgents: hostAgents,
    otherAgents: otherAgents,
    workers: workers,
    myDevices: myDevices,
    hostOnline: hostOnline,
    hostIsThisComputer:
        sameFingerprint(hostPeer?.fingerprint, localCliFingerprint),
    rosterFailed: rosterFailed,
  );
}

String? _rosterFingerprint(Agent agent) {
  final raw = agent.metadata?['roster_hub_fingerprint'];
  if (raw is! String) return null;
  final trimmed = raw.trim().toLowerCase();
  return trimmed.isEmpty ? null : trimmed;
}

/// 通讯录快照。失败、离线和空名单各自保留，不把异常收成空列表。
class ContactsDirectory {
  ContactsDirectory();

  final _snapshots = StreamController<ContactsView>.broadcast();
  Stream<ContactsView> get snapshots => _snapshots.stream;

  ContactsView? _latest;
  ContactsView? get latest => _latest;

  List<PairedPeer>? _rosterCache;
  List<Agent> _agentCache = const [];
  bool _started = false;
  bool _refreshing = false;
  bool _again = false;

  StreamSubscription<void>? _peerListSub;
  StreamSubscription<PeerConnectionEvent>? _connectionSub;
  StreamSubscription<void>? _reloggedSub;
  StreamSubscription<void>? _agentsSub;

  void start() {
    if (_started) return;
    _started = true;
    _peerListSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) {
      unawaited(refresh());
    });
    _connectionSub = PeerConnectionManager.instance.events.listen((event) {
      if (event.type == PeerConnectionEventType.connected ||
          event.type == PeerConnectionEventType.disconnected) {
        unawaited(refresh());
      }
    });
    _reloggedSub = PouchLoginKeeper.instance.relogged.listen((_) {
      unawaited(refresh());
    });
    if (getIt.isRegistered<RemoteAgentService>()) {
      _agentsSub = getIt<RemoteAgentService>().agentsChanged.listen((_) {
        unawaited(refresh());
      });
    }
  }

  Future<void> refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _refreshOnce();
      } while (_again);
    } finally {
      _refreshing = false;
    }
  }

  /// 本机主机走 [CliHost.attach]，远端主机重拨。
  Future<void> reconnectHost() async {
    final host = _latest?.host;
    if (host == null) return;
    final cli = await CliHost.detect();
    if (cli != null && sameFingerprint(cli.fingerprint, host.fingerprint)) {
      try {
        await CliHost.attach(cli);
      } on HostUnresponsiveException {
        // 刷新后仍显示离线。
      }
    } else {
      try {
        await PeerConnectionManager.instance.connectToPeer(
          host,
          ignoreTieBreak: true,
        );
      } catch (_) {}
    }
    await refresh();
  }

  Future<void> dispose() async {
    await _peerListSub?.cancel();
    await _connectionSub?.cancel();
    await _reloggedSub?.cancel();
    await _agentsSub?.cancel();
    await _snapshots.close();
  }

  Future<void> _refreshOnce() async {
    final session = await PouchSessionStore.readActive();
    final hostId = session?.hostPeerId.trim() ?? '';
    if (session == null || hostId.isEmpty) {
      _emit(ContactsView.empty);
      return;
    }

    final hostOnline =
        PeerConnectionManager.instance.connectedPeerIds.contains(hostId);
    final hostPeer = await PeerStorageService().getPeerById(hostId);
    final agents = await _readAgents();
    final cli = await CliHost.detect();
    final appFingerprint = await _readAppFingerprint();

    var roster = _rosterCache ?? const <PairedPeer>[];
    var rosterFailed = false;
    if (hostOnline) {
      try {
        roster = await PouchPairing.visiblePeers();
        _rosterCache = roster;
      } catch (_) {
        rosterFailed = true;
        roster = const <PairedPeer>[];
      }
    }

    _emit(buildContacts(
      hostPeerId: hostId,
      hostPeer: hostPeer,
      roster: roster,
      agents: agents,
      appFingerprint: appFingerprint,
      localCliFingerprint: cli?.fingerprint,
      connectedPeerIds:
          PeerConnectionManager.instance.connectedPeerIds.toSet(),
      rosterFailed: rosterFailed,
    ));
  }

  Future<List<Agent>> _readAgents() async {
    try {
      final agents = await LocalApiService().getAgents();
      _agentCache = agents;
      return agents;
    } catch (_) {
      return _agentCache;
    }
  }

  Future<String?> _readAppFingerprint() async {
    try {
      return await DeviceIdentity.deviceId();
    } catch (_) {
      return null;
    }
  }

  void _emit(ContactsView view) {
    _latest = view;
    if (!_snapshots.isClosed) _snapshots.add(view);
  }
}
