import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/services/contacts_directory.dart';
import 'package:shepaw/services/contacts_rows.dart';

void main() {
  PairedPeer peer(
    String id,
    String name,
    String fingerprint, {
    PeerConnectionState state = PeerConnectionState.disconnected,
    String? role,
    String? platform,
  }) =>
      PairedPeer(
        id: id,
        deviceName: name,
        deviceId: id,
        publicKey: Uint8List(32),
        fingerprint: fingerprint,
        pairedAt: 1000,
        state: state,
        nodeRole: role,
        platform: platform,
      );

  Agent agent(
    String id,
    String name, {
    String bio = '',
    Map<String, dynamic> node = const {},
  }) =>
      Agent(
        id: id,
        name: name,
        avatar: '🤖',
        bio: bio,
        metadata: {...node},
        provider: const AgentProvider(name: '', platform: '', type: ''),
        status: const AgentStatus(state: 'online'),
      );

  Channel group(String id, String name, {String? description}) => Channel(
        id: id,
        name: name,
        type: 'group',
        description: description,
        members: const [],
        createdAt: 0,
      );

  /// 一台主机（挂两个 Agent）、一个在线工作节点（挂一个）、一台手机客户端。
  ContactsView view() {
    final host = peer('host-peer', 'MacBook Pro', 'aaaa1111',
        state: PeerConnectionState.connected, role: NodeRole.host);
    final node = peer('node-peer', 'NAS', 'bbbb2222',
        state: PeerConnectionState.connected, role: NodeRole.worker);
    final phone = peer('phone-peer', 'Pixel', 'cccc3333',
        platform: 'android');
    return ContactsView(
      hasSession: true,
      host: host,
      devices: [
        ContactDevice(
          peer: host,
          agents: [agent('a1', 'She'), agent('a2', 'Coder')],
          isHost: true,
          isThisDevice: true,
          online: true,
        ),
        ContactDevice(
          peer: node,
          agents: [agent('a3', 'Backup')],
          isHost: false,
          isThisDevice: false,
          online: true,
        ),
        ContactDevice(
          peer: phone,
          agents: const [],
          isHost: false,
          isThisDevice: false,
          online: false,
        ),
      ],
      // 来源对不上设备的 Agent，不该再挂在主机下面。
      otherAgents: [agent('a9', 'Stray')],
      hostOnline: true,
      hostIsThisComputer: true,
      rosterFailed: false,
    );
  }

  /// l10n 只能从 Widget 树里取。
  Future<AppLocalizations> l10nOf(WidgetTester tester) async {
    late AppLocalizations resolved;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            resolved = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    return resolved;
  }

  testWidgets('联系人分段：群聊在最前，Agent 按节点分组，未归属单独一组',
      (tester) async {
    final l10n = await l10nOf(tester);
    final rows = ContactsRows.build(
      view: view(),
      groups: [group('g1', '产品讨论组')],
      query: '',
      showDevices: false,
      l10n: l10n,
    );

    final kinds = rows.map((r) => r.kind).toList();
    // 群聊标题 → 群聊行 → 主机标题 → 两个 Agent → 节点标题 → 一个 Agent
    // → 未归属标题 → 一个 Agent。
    expect(kinds, [
      ContactsRowKind.header,
      ContactsRowKind.group,
      ContactsRowKind.header,
      ContactsRowKind.agent,
      ContactsRowKind.agent,
      ContactsRowKind.header,
      ContactsRowKind.agent,
      ContactsRowKind.header,
      ContactsRowKind.agent,
    ]);
    expect(rows[1].group!.name, '产品讨论组');
    expect(rows[3].agent!.name, 'She');
    expect(rows.last.agent!.name, 'Stray');
    // 没有 Agent 的节点不出现在联系人分段。
    expect(rows.where((r) => r.title == 'Pixel'), isEmpty);
  });

  testWidgets('未归属的 Agent 不再挂在主机下', (tester) async {
    final l10n = await l10nOf(tester);
    final rows = ContactsRows.build(
      view: view(),
      groups: const [],
      query: '',
      showDevices: false,
      l10n: l10n,
    );

    final hostIndex = rows.indexWhere(
      (r) => r.kind == ContactsRowKind.header && r.title == 'MacBook Pro',
    );
    final unassignedIndex = rows.indexWhere(
      (r) => r.kind == ContactsRowKind.header && r.title == l10n.contacts_unassigned,
    );
    expect(hostIndex, greaterThan(0));
    expect(unassignedIndex, greaterThan(hostIndex));
    // 未归属组里只有那个对不上设备的 Agent，主机自己的 Agent 在它前面。
    expect(
      rows
          .sublist(unassignedIndex + 1)
          .where((r) => r.kind == ContactsRowKind.agent)
          .map((r) => r.agent!.name)
          .toList(),
      ['Stray'],
    );
    final hostAgents = rows
        .sublist(hostIndex + 1, unassignedIndex)
        .where((r) => r.kind == ContactsRowKind.agent)
        .map((r) => r.agent!.name)
        .toList();
    expect(hostAgents, containsAll(['She', 'Coder', 'Backup']));
    expect(hostAgents, isNot(contains('Stray')));
  });

  testWidgets('设备名命中时显示它名下的全部 Agent', (tester) async {
    final l10n = await l10nOf(tester);
    final rows = ContactsRows.build(
      view: view(),
      groups: const [],
      query: 'macbook',
      showDevices: false,
      l10n: l10n,
    );

    // 命中设备名的是设备行，它名下的 Agent 不再被关键词过滤掉。
    final devices = rows.where((r) => r.kind == ContactsRowKind.device).toList();
    expect(devices.single.device!.peer.deviceName, 'MacBook Pro');
    expect(
      rows.where((r) => r.kind == ContactsRowKind.agent),
      isEmpty,
      reason: '搜设备名时 Agent 不单独成行，而是在设备详情里看',
    );
  });

  testWidgets('搜索群聊不受折叠状态影响', (tester) async {
    final l10n = await l10nOf(tester);
    final rows = ContactsRows.build(
      view: view(),
      groups: [
        group('g1', '产品讨论组'),
        group('g2', '值班', description: 'oncall'),
      ],
      query: 'oncall',
      showDevices: false,
      l10n: l10n,
    );

    // 命中描述也算。搜索结果平铺，没有折叠状态可遵循。
    expect(
      rows.where((r) => r.kind == ContactsRowKind.group).map((r) => r.group!.id),
      ['g2'],
    );
  });

  testWidgets('Agent 搜索命中名字和简介，并显示所属节点', (tester) async {
    final l10n = await l10nOf(tester);
    final v = ContactsView(
      hasSession: true,
      host: view().host,
      devices: [
        ContactDevice(
          peer: peer('node-peer', 'NAS', 'bbbb2222', role: NodeRole.worker),
          agents: [agent('a3', 'Backup', bio: '每天凌晨跑')],
          isHost: false,
          isThisDevice: false,
          online: true,
        ),
      ],
      otherAgents: const [],
      hostOnline: true,
      hostIsThisComputer: true,
      rosterFailed: false,
    );
    final rows = ContactsRows.build(
      view: v,
      groups: const [],
      query: '凌晨',
      showDevices: false,
      l10n: l10n,
    );

    final agents = rows.where((r) => r.kind == ContactsRowKind.agent).toList();
    expect(agents.single.agent!.name, 'Backup');
    expect(agents.single.parentName, 'NAS');
  });

  testWidgets('设备分段：主机 → 工作节点 → 客户端，带单位计数', (tester) async {
    final l10n = await l10nOf(tester);
    final rows = ContactsRows.build(
      view: view(),
      groups: const [],
      query: '',
      showDevices: true,
      l10n: l10n,
    );

    expect(
      rows.where((r) => r.kind == ContactsRowKind.device).map((r) => r.device!.peer.deviceName),
      ['MacBook Pro', 'NAS', 'Pixel'],
    );
    final header = rows.firstWhere(
      (r) => r.kind == ContactsRowKind.header && r.title == l10n.contacts_workerNodes,
    );
    expect(header.countLabel, l10n.contacts_deviceCount(1));
    // 设备分段里没有 Agent 行，Agent 只在联系人分段和详情页里。
    expect(rows.where((r) => r.kind == ContactsRowKind.agent), isEmpty);
  });
}
