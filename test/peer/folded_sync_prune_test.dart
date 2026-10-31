import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';
import 'package:shepaw/services/app_lifecycle_service.dart';

/// 折叠主机上真正跑一遍同步（真服务 + 真数据库）：引擎客户端 / 终端会话的
/// 本地副本要被清掉，私聊留下。
///
/// 之前只测了纯函数 [peerChannelIdsAbsentFromHost]，没覆盖 `syncSessions`
/// 里"折叠主机强制不再镜像客户端会话"这一段，也没覆盖数据库真删掉。
void main() {
  final svc = PeerAgentClientService.instance;
  late LocalDatabaseService db;
  var seq = 0;

  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    db = LocalDatabaseService();
    await db.database;
  });

  String next(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${++seq}';

  /// 建一个 agent + 两个频道：一个是主机名单里的私聊，一个是终端会话副本。
  Future<({String agentId, String mine, String terminal, String sheChat})>
      seed() async {
    final local = next('agent');
    await db.createRemoteAgent(RemoteAgent(
      id: local,
      name: 'agent',
      token: 't',
      endpoint: 'http://127.0.0.1:0',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      metadata: const {
        'engine': 'cursor',
        'source_peer_id': 'p1',
        'remote_agent_id': 'a1'
      },
      createdAt: 0,
      updatedAt: 0,
    ));
    final mine = 'psess_${next('mine')}';
    final terminal = 'psess_${next('term')}';
    for (final entry in [(mine, null), (terminal, 'terminal')]) {
      await db.createChannel(
        Channel.withMemberIds(
          id: entry.$1,
          name: entry.$1,
          type: 'dm',
          memberIds: ['user', local],
          isPrivate: true,
          sessionOrigin: entry.$2,
        ),
        'user',
      );
    }
    // 群绑定的会话不该被碰（哪怕主机名单里没有）。
    final sheChat = next('dm');
    await db.createChannel(
      Channel.withMemberIds(
        id: sheChat,
        name: '群绑定',
        type: 'dm',
        memberIds: ['user', local],
        isPrivate: true,
        sourceSheChannelId: 'group_1',
      ),
      'user',
    );
    return (agentId: local, mine: mine, terminal: terminal, sheChat: sheChat);
  }

  List<PeerRemoteSession> hostList(String mine) => [
        PeerRemoteSession(
          sessionId: mine.replaceFirst('psess_', ''),
          title: 'mine',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ];

  Future<void> sync(String local, List<PeerRemoteSession> sessions) =>
      svc.syncSessions(
        peerId: 'p1',
        remoteAgentId: 'a1',
        localAgentId: local,
        userId: 'user',
        sessions: sessions,
        pruneToHost: true,
        // 调用方按"同步客户端会话"开关传的：开着是 false（名单里有它们），
        // 关着是 true（名单里没有）。折叠主机两者都不该镜像。
        preserveClientSessions: true,
      );

  test('on a folded host the mirrored terminal session is dropped from the db',
      () async {
    final s = await seed();
    svc.debugMarkFolded('p1', 'a1', true);
    addTearDown(() => svc.debugMarkFolded('p1', 'a1', false));

    await sync(s.agentId, hostList(s.mine));

    expect(await db.getChannelById(s.mine), isNotNull);
    expect(await db.getChannelById(s.terminal), isNull);
    expect(await db.getChannelById(s.sheChat), isNotNull);
  });

  test('an old host (no folders) still mirrors terminal sessions', () async {
    final s = await seed();
    svc.debugMarkFolded('p1', 'a1', false);

    final sessions = [
      ...hostList(s.mine),
      PeerRemoteSession(
        sessionId: s.terminal.replaceFirst('psess_', ''),
        title: 'term',
        source: 'terminal',
      ),
    ];
    await sync(s.agentId, sessions);

    // 名单里有它们（preserveClientSessions 为 true 时更不会被剪）。
    expect(await db.getChannelById(s.terminal), isNotNull);

    // 老主机名单里没有终端会话、又开着同步开关：旧行为是删掉的。
    final s2 = await seed();
    await svc.syncSessions(
      peerId: 'p1',
      remoteAgentId: 'a1',
      localAgentId: s2.agentId,
      userId: 'user',
      sessions: hostList(s2.mine),
      pruneToHost: true,
      preserveClientSessions: false,
    );
    expect(await db.getChannelById(s2.terminal), isNull);
  });

  test('a terminal session the user is reading survives until they leave it',
      () async {
    final s = await seed();
    svc.debugMarkFolded('p1', 'a1', true);
    AppLifecycleService().activeChannelId = s.terminal;
    addTearDown(() {
      AppLifecycleService().activeChannelId = null;
      svc.debugMarkFolded('p1', 'a1', false);
    });

    await sync(s.agentId, hostList(s.mine));
    // 正在看：受保护，先留下（用户不会看着看着会话没了）。
    expect(await db.getChannelById(s.terminal), isNotNull);

    // 离开之后的下一次同步才清掉。留着的时候它不再进历史同步，
    // 内容按需从主机的折叠组里读。
    AppLifecycleService().activeChannelId = null;
    await sync(s.agentId, hostList(s.mine));
    expect(await db.getChannelById(s.terminal), isNull);
  });

  test('the digest marks every agent folded; she stays unfolded', () async {
    final mgr = PeerConnectionManager.instance;
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    mgr.debugTrySendControlOverride = (peerId, json) async {
      sent.add(json);
      // 折叠主机：每个 Agent 的条目是 {sessions, folders}；惜宝仍是数组。
      unawaited(Future<void>.delayed(Duration.zero, () {
        bus.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'agent_sessions_digest_resp',
            'request_id': json['request_id'],
            'digests': {
              'a1': {'sessions': <Object>[], 'folders': <Object>[]},
              'she': <Object>[],
            },
          },
        ));
      }));
      return true;
    };
    // 摘要帧走 PeerConnectionManager 的控制流，服务靠它认领回包。
    final sub = bus.stream.listen((event) => svc.debugHandleControl(event));
    addTearDown(() async {
      mgr.debugTrySendControlOverride = null;
      await sub.cancel();
      await bus.close();
      svc.debugMarkFolded('p1', 'a1', false);
      svc.debugMarkFolded('p1', 'she', false);
    });

    final got = await svc.fetchSessionsDigest(peerId: 'p1');
    expect(sent.single['type'], 'agent_sessions_digest_req');
    expect(sent.single['view'], 'folded');
    expect(got, isNotNull);
    expect(svc.isHostFolded('p1', 'a1'), isTrue);
    expect(svc.isHostFolded('p1', 'she'), isFalse);
  });
}
