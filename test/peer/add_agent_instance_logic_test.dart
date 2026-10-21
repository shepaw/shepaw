import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/add_agent_instance_logic.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/screens/add_agent_instance_screen.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/storage/pouch_session.dart';

PairedPeer _peer({
  required String id,
  required String name,
  String? nodeRole,
}) {
  return PairedPeer(
    id: id,
    deviceName: name,
    deviceId: id,
    publicKey: Uint8List(32),
    fingerprint: id,
    pairedAt: 1,
    nodeRole: nodeRole,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = PeerAgentClientService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AddAgentInstanceScreen.draft = null;
  });

  tearDown(() {
    svc.debugResetPeerMetaForTest();
    AddAgentInstanceScreen.draft = null;
    AddAgentInstanceScreen.debugReadSessionOverride = null;
    AddAgentInstanceScreen.debugLoadPeersOverride = null;
  });
  test('不可用的引擎排到后面，组内顺序不变', () {
    final sorted = sortEnginesUnavailableLast(
      ['codex', 'claude', 'cursor', 'kimi'],
      (id) => id == 'claude' || id == 'kimi',
    );
    expect(sorted, ['claude', 'kimi', 'codex', 'cursor']);
  });

  test('引擎关键词匹配子串和子序列', () {
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: ''),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'code'),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'cc'),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'zzz'),
      isFalse,
    );
  });

  test('目录历史去重并把最新的放在前面，超过 30 条截断', () {
    final deduped = rememberCwd(['/work/1', '/tmp'], '/work/1/');
    expect(deduped, ['/work/1/', '/tmp']);
    final history = [for (var i = 0; i < 30; i++) '/work/$i'];
    final next = rememberCwd(history, '/work/new');
    expect(next.first, '/work/new');
    expect(next.length, 30);
    expect(next.contains('/work/29'), isFalse);
  });

  test('已有实例的目录接在本地历史后面，相同路径不重复', () {
    final merged = mergeCwdSuggestions(
      ['/home/me/app/', '/tmp/other'],
      ['/home/me/app', '/srv/new'],
    );
    expect(merged, ['/home/me/app/', '/tmp/other', '/srv/new']);
  });

  test('工作节点的目标键和最近目录键带上节点指纹，主机沿用原来的键', () {
    const host = AgentTarget(peerId: 'hub', name: 'Hub', online: true);
    const worker = AgentTarget(
      peerId: 'hub',
      nodeId: 'fc57',
      name: 'gpu-box',
      online: false,
    );
    expect(host.key, 'hub');
    expect(worker.key, 'hub@fc57');
    expect(cwdHistoryKey('hub', null), 'agent_instance_cwd_history:hub');
    expect(cwdHistoryKey('hub', 'fc57'), 'agent_instance_cwd_history:hub@fc57');
  });

  testWidgets('打开添加页只发一次 engines、不阻塞于慢 fs_browse 或旁路设备，创建后立即回调',
      (tester) async {
    AddAgentInstanceScreen.debugReadSessionOverride = () async => const PouchSession(
          hubUrl: 'ws://127.0.0.1:1/peer/ws',
          pouchId: 'pouch-1',
          pouchName: '书房',
          hostPeerId: 'host-1',
          token: 'tok',
          sessionId: 'sid-1',
          expiresAtMs: 9999999999999,
        );
    AddAgentInstanceScreen.debugLoadPeersOverride = () async => [
          _peer(id: 'host-1', name: '主机'),
          // 另一台已连接但不会响应 agent_manage_req 的设备：不应阻塞主机加载。
          _peer(id: 'other-1', name: '旁路设备'),
        ];
    svc.debugConnectedPeerIdsOverride = {'host-1', 'other-1'};

    final sentToHost = <Map<String, dynamic>>[];
    String? pendingFsBrowseReqId;
    svc.debugSendControlOverride = (peerId, json) async {
      if (peerId != 'host-1') {
        // 模拟旁路设备不回包。
        return true;
      }
      sentToHost.add(Map<String, dynamic>.from(json));
      final type = json['type'] as String?;
      final reqId = json['request_id'] as String?;
      if (type == 'agent_manage_req' && json['op'] == 'engines') {
        scheduleMicrotask(() {
          svc.debugInjectControlForTest(
            'agent_manage_resp',
            {
              'request_id': reqId,
              'ok': true,
              'engines': [
                {
                  'id': 'claude-code',
                  'name': 'Claude Code',
                  'command': 'claude',
                  'available': true,
                  'session_modes': const [],
                },
              ],
              'agents': [
                {
                  'id': 'existing-1',
                  'name': 'Existing',
                  'engine': 'claude-code',
                  'cwd': '/work/existing',
                  'running': true,
                  'enabled': true,
                  'manageable': true,
                },
              ],
            },
            peerId: 'host-1',
          );
        });
      } else if (type == 'fs_browse_req') {
        // 故意挂起主目录查询，验证不会卡住整个页面转圈。
        pendingFsBrowseReqId = reqId;
      } else if (type == 'agent_manage_req' && json['op'] == 'create') {
        scheduleMicrotask(() {
          svc.debugInjectControlForTest(
            'agent_manage_resp',
            {
              'request_id': reqId,
              'ok': true,
              'agent_id': 'inst-new@node-1',
              'agents': [
                {
                  'id': 'inst-new@node-1',
                  'name': json['name'] ?? 'Claude Code',
                  'engine': 'claude-code',
                  'cwd': json['cwd'] ?? '/work/existing',
                  'running': true,
                  'enabled': true,
                  'manageable': true,
                },
              ],
              'engines': const [],
            },
            peerId: 'host-1',
          );
        });
      }
      return true;
    };

    RemoteAgent? createdAgent;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddAgentInstanceScreen(
          embedded: true,
          onCreated: (agent) => createdAgent = agent,
        ),
      ),
    );

    // 等 300ms fs_browse 宽限窗口走完，表单应已渲染出来，不再无限转圈。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('/work/existing'), findsOneWidget);
    // 只发了一次 op: 'engines'，没有重复发 op: 'list'。
    expect(
      sentToHost
          .where((m) => m['type'] == 'agent_manage_req')
          .map((m) => m['op'])
          .toList(),
      ['engines'],
    );

    // 迟到的 fs_browse_resp 返回后，自动回填默认主目录与名称。
    svc.debugInjectControlForTest(
      'fs_browse_resp',
      {
        'request_id': pendingFsBrowseReqId,
        'ok': true,
        'path': '/Users/me/project',
        'entries': const [],
      },
      peerId: 'host-1',
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('/Users/me/project'), findsOneWidget);

    // 点击创建：不依赖 agent_list_resp 返回即可立即拿到新实例并触发 onCreated。
    final submitButton = find.byType(FilledButton);
    await tester.scrollUntilVisible(
      submitButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(submitButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(createdAgent, isNotNull);
    expect(createdAgent!.id, 'inst-new@node-1');
    expect(createdAgent!.remoteAgentId, 'inst-new@node-1');
    expect(createdAgent!.name, 'project');

    // 收尾掉后台 _probeOtherTargets 的 5s 定时器。
    await tester.pump(const Duration(seconds: 6));
  });

  test('manageAgents 在收到 pouch_login_required 时不苦等 15s 超时，立刻以 login_required 退出单次等待',
      () async {
    svc.debugConnectedPeerIdsOverride = {'host-1'};
    svc.debugSendControlOverride = (peerId, json) async {
      scheduleMicrotask(() {
        svc.debugInjectControlForTest(
          'pouch_login_required',
          {'for': 'pouch_sealed'},
          peerId: 'host-1',
        );
      });
      return true;
    };

    final started = DateTime.now();
    final result = await svc.manageAgents(
      peerId: 'host-1',
      op: 'engines',
      timeout: const Duration(seconds: 15),
    );
    // PouchLoginKeeper.waitForRelogin 在没有真实重登时 8s 超时收尾，远短于 15s + 15s。
    expect(result.ok, isFalse);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
  });
}
