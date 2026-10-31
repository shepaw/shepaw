import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import 'contacts_directory.dart';

/// 通讯录列表的分段。搜索时两类一起出。
enum ContactsRowKind { header, groupHint, agent, group, device }

/// 通讯录列表里的一行。标题也算一行，键盘上下键要跳过它们。
///
/// 抽出来是为了让「谁排在前、Agent 挂在哪、搜索怎么过滤」能脱离 Widget
/// 单独测：原来这些规则埋在 State 里，只能靠肉眼看。
class ContactsRow {
  const ContactsRow._({
    required this.kind,
    this.title,
    this.countLabel,
    this.device,
    this.agent,
    this.group,
    this.parentName,
  });

  const ContactsRow.header(String title, [String? countLabel])
      : this._(kind: ContactsRowKind.header, title: title, countLabel: countLabel);

  const ContactsRow.groupHint()
      : this._(kind: ContactsRowKind.groupHint);

  const ContactsRow.device(ContactDevice device)
      : this._(kind: ContactsRowKind.device, device: device);

  const ContactsRow.agent(Agent agent, {String? parentName})
      : this._(kind: ContactsRowKind.agent, agent: agent, parentName: parentName);

  const ContactsRow.group(Channel group)
      : this._(kind: ContactsRowKind.group, group: group);

  final ContactsRowKind kind;
  final String? title;
  final String? countLabel;
  final ContactDevice? device;
  final Agent? agent;
  final Channel? group;

  /// Agent 所属节点名，只在搜索结果里显示。
  final String? parentName;

  bool get isSelectable =>
      kind != ContactsRowKind.header && kind != ContactsRowKind.groupHint;

  String get key {
    switch (kind) {
      case ContactsRowKind.header:
        return 'header:${title ?? ''}';
      case ContactsRowKind.groupHint:
        return 'hint:groups';
      case ContactsRowKind.device:
        return 'device:${device!.rowKey}';
      case ContactsRowKind.agent:
        return 'agent:${agent!.id}';
      case ContactsRowKind.group:
        return 'group:${group!.id}';
    }
  }
}

/// 把通讯录快照排成一层列表。
///
/// 联系人分段：群聊在前，Agent 按节点分组铺开，对不上设备的 Agent 单独一组。
/// 设备分段：主机 → 工作节点 → 客户端。
/// 搜索时按类型平铺，不受任何折叠状态影响。
class ContactsRows {
  ContactsRows._();

  static List<ContactsRow> build({
    required ContactsView view,
    required List<Channel> groups,
    required String query,
    required bool showDevices,
    required AppLocalizations l10n,
  }) {
    if (query.isNotEmpty) return _search(view, groups, query, l10n);
    return showDevices ? _devices(view, l10n) : _people(view, groups, l10n);
  }

  static bool _agentMatches(Agent agent, String query) {
    if (query.isEmpty) return true;
    final name = agent.name.toLowerCase();
    final bio = agent.bio?.toLowerCase() ?? '';
    return name.contains(query) || bio.contains(query);
  }

  /// 设备名命中时不再按关键词过滤它名下的 Agent：搜「MacBook」的人就是想看
  /// 这台设备上有什么，而那些 Agent 的名字里并没有这个词。
  static bool _deviceNameMatches(ContactDevice device, String query) =>
      query.isNotEmpty && device.peer.deviceName.toLowerCase().contains(query);

  static List<Agent> _agentsOf(ContactDevice device, String query) {
    if (_deviceNameMatches(device, query)) return device.agents;
    return device.agents.where((a) => _agentMatches(a, query)).toList();
  }

  static List<Channel> _groupsMatching(List<Channel> groups, String query) {
    if (query.isEmpty) return groups;
    return groups
        .where((g) =>
            g.name.toLowerCase().contains(query) ||
            (g.description?.toLowerCase().contains(query) ?? false))
        .toList();
  }

  static List<ContactsRow> _people(
    ContactsView view,
    List<Channel> groups,
    AppLocalizations l10n,
  ) {
    final rows = <ContactsRow>[
      ContactsRow.header(l10n.contacts_groups, '${groups.length}'),
      ...groups.map(ContactsRow.group),
    ];
    if (groups.isEmpty) rows.add(const ContactsRow.groupHint());

    // 节点只作为不可折叠的小标题，Agent 直接铺开。
    for (final device in view.devices) {
      final agents = _agentsOf(device, '');
      if (agents.isEmpty) continue;
      rows.add(ContactsRow.header(device.peer.deviceName, _nodeStatus(view, device, l10n)));
      rows.addAll(agents.map(ContactsRow.agent));
    }

    // 来源对不上设备的 Agent 原来挂在主机下面叫「其他」，会让人以为它们在
    // 主机上，现在单独一组。
    final unassigned = view.otherAgents;
    if (unassigned.isNotEmpty) {
      rows.add(ContactsRow.header(l10n.contacts_unassigned));
      rows.addAll(unassigned.map(ContactsRow.agent));
    }
    return rows;
  }

  static String? _nodeStatus(
    ContactsView view,
    ContactDevice device,
    AppLocalizations l10n,
  ) {
    if (device.isHost) {
      return view.hostOnline ? null : l10n.contacts_nodeOffline;
    }
    if (device.section == ContactSection.worker && !device.online) {
      return l10n.contacts_nodeOffline;
    }
    return null;
  }

  static List<ContactsRow> _devices(ContactsView view, AppLocalizations l10n) {
    final host = view.devices.where((d) => d.isHost).toList();
    final workers =
        view.devices.where((d) => d.section == ContactSection.worker).toList();
    final clients = view.devices
        .where((d) =>
            d.section == ContactSection.pcClient ||
            d.section == ContactSection.mobileClient)
        .toList();

    return [
      if (host.isNotEmpty) ...[
        ContactsRow.header(l10n.contacts_host),
        ...host.map(ContactsRow.device),
      ],
      if (workers.isNotEmpty) ...[
        ContactsRow.header(
          l10n.contacts_workerNodes,
          l10n.contacts_deviceCount(workers.length),
        ),
        ...workers.map(ContactsRow.device),
      ],
      if (clients.isNotEmpty) ...[
        ContactsRow.header(
          l10n.contacts_clients,
          l10n.contacts_deviceCount(clients.length),
        ),
        ...clients.map(ContactsRow.device),
      ],
    ];
  }

  static List<ContactsRow> _search(
    ContactsView view,
    List<Channel> groups,
    String query,
    AppLocalizations l10n,
  ) {
    final rows = <ContactsRow>[];

    final agents = <ContactsRow>[];
    for (final device in view.devices) {
      // 设备名命中的设备不贡献 Agent 行，它们的 Agent 在设备行下面看。
      if (_deviceNameMatches(device, query)) continue;
      for (final agent in device.agents) {
        if (!_agentMatches(agent, query)) continue;
        agents.add(ContactsRow.agent(agent, parentName: device.peer.deviceName));
      }
    }
    for (final agent in view.otherAgents) {
      if (_agentMatches(agent, query)) agents.add(ContactsRow.agent(agent));
    }

    final matchedGroups = _groupsMatching(groups, query);
    final devices = view.devices.where((d) => _deviceNameMatches(d, query));

    if (agents.isNotEmpty) {
      rows.add(ContactsRow.header(l10n.contacts_searchAgents));
      rows.addAll(agents);
    }
    if (matchedGroups.isNotEmpty) {
      rows.add(ContactsRow.header(
        l10n.contacts_groups,
        '${matchedGroups.length}',
      ));
      rows.addAll(matchedGroups.map(ContactsRow.group));
    }
    if (devices.isNotEmpty) {
      rows.add(ContactsRow.header(l10n.contacts_searchDevices));
      rows.addAll(devices.map(ContactsRow.device));
    }
    return rows;
  }
}
