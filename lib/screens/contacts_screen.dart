import 'dart:async';

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/widgets/peer_device_icon.dart';
import '../peer/screens/add_agent_instance_screen.dart';
import '../peer/screens/peer_manual_input_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../utils/platform_utils.dart';
import '../services/contacts_directory.dart';
import '../services/local_database_service.dart';
import '../services/she_service.dart';
import '../services/logger_service.dart';
import '../service_locator.dart';
import '../widgets/avatar_image.dart';
import '../widgets/mobile_shell_scope.dart';
import '../models/remote_agent.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';
import 'create_group_screen.dart';

/// 通讯录：全部设备平铺（主机、本机只在设备名旁标出来）→ 群聊。
/// App 自己不列一份内置 Agent。
///
/// When [embedded] is true (desktop middle column), selection callbacks open
/// details in the parent right panel instead of pushing a new route.
class ContactsScreen extends StatefulWidget {
  final bool embedded;
  final String? selectedContactId;
  final ValueChanged<RemoteAgent>? onAgentSelected;
  final ValueChanged<Channel>? onGroupSelected;
  final ValueChanged<PairedPeer>? onPeerSelected;
  final VoidCallback? onCreateGroup;
  final VoidCallback? onPairDevice;
  final VoidCallback? onAddAgentInstance;

  const ContactsScreen({
    super.key,
    this.embedded = false,
    this.selectedContactId,
    this.onAgentSelected,
    this.onGroupSelected,
    this.onPeerSelected,
    this.onCreateGroup,
    this.onPairDevice,
    this.onAddAgentInstance,
  });

  @override
  State<ContactsScreen> createState() => ContactsScreenState();
}

enum _ContactsSection { groups }

class ContactsScreenState extends State<ContactsScreen> {
  /// 折叠箭头列宽 + 间距，使子项头像与父节点头像左对齐。
  static const double _rowPadH = 12;
  static const double _chevronSize = 20;
  static const double _chevronGap = 4;
  static const double _avatarSize = 36;
  static const double _childIndent =
      _rowPadH + _chevronSize + _chevronGap; // 对齐父节点头像

  final LocalDatabaseService _databaseService = LocalDatabaseService();
  final TextEditingController _searchController = TextEditingController();
  late final ContactsDirectory _directory;

  ContactsView? _view;
  bool _pinnedHost = false;
  List<Channel> _groups = [];
  bool _isLoading = true;
  String _query = '';

  final Set<_ContactsSection> _expanded = {
    _ContactsSection.groups,
  };

  /// Peer ids whose nested agent list is expanded.
  final Set<String> _expandedPeerIds = {};

  StreamSubscription<ContactsView>? _directorySub;

  /// 外部（桌面端新建助手/群/配对后）触发的刷新：列表已有内容，静默更新即可，
  /// 不必把整页换成转圈。
  Future<void> reload() => _reload(quiet: true);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final next = _searchController.text.trim().toLowerCase();
      if (next != _query) {
        setState(() => _query = next);
      }
    });
    _directory = getIt<ContactsDirectory>();
    _directory.start();
    final cached = _directory.latest;
    if (cached != null) {
      _view = cached;
      _isLoading = false;
    }
    _directorySub = _directory.snapshots.listen((view) {
      if (!mounted) return;
      setState(() {
        _view = view;
        _isLoading = false;
        final hostId = view.host?.id;
        if (hostId != null && !_pinnedHost) {
          _expandedPeerIds.add(hostId);
          _pinnedHost = true;
        }
      });
    });
    _reload(quiet: cached != null);
  }

  @override
  void dispose() {
    _directorySub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the selected peer's agent list expanded when details open on the right.
    final selected = widget.selectedContactId;
    if (selected != null &&
        selected != oldWidget.selectedContactId &&
        _peerIds.any((id) => id == selected)) {
      _expandedPeerIds.add(selected);
    }
  }

  Future<void> _reload({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _isLoading = true);
    try {
      final groups = await _databaseService.getTopLevelGroups();
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      LoggerService().error('Failed to load groups', tag: 'Contacts', error: e);
    }
    await _directory.refresh();
    if (mounted) setState(() => _isLoading = false);
  }

  List<String> get _peerIds {
    final view = _view;
    if (view == null) return const [];
    return [for (final device in view.devices) device.peer.id];
  }

  List<Agent> _matchingAgents(List<Agent> agents) {
    if (_query.isEmpty) return agents;
    return agents.where(_agentMatchesQuery).toList();
  }

  bool _agentMatchesQuery(Agent a) {
    final name = a.name.toLowerCase();
    final bio = a.bio?.toLowerCase() ?? '';
    return name.contains(_query) || bio.contains(_query);
  }

  List<Channel> get _filteredGroups {
    if (_query.isEmpty) return _groups;
    return _groups
        .where((g) =>
            g.name.toLowerCase().contains(_query) ||
            (g.description?.toLowerCase().contains(_query) ?? false))
        .toList();
  }

  void _toggleSection(_ContactsSection section) {
    setState(() {
      if (_expanded.contains(section)) {
        _expanded.remove(section);
      } else {
        _expanded.add(section);
      }
    });
  }

  void _togglePeerExpanded(PairedPeer peer) {
    setState(() {
      if (_expandedPeerIds.contains(peer.id)) {
        _expandedPeerIds.remove(peer.id);
      } else {
        _expandedPeerIds.add(peer.id);
      }
    });
  }

  /// Desktop: expand + show detail in the right panel.
  /// Mobile: expand/collapse only — settings via info button or long-press menu.
  void _onPeerTap(PairedPeer peer) {
    _togglePeerExpanded(peer);
    if (widget.embedded) {
      _openPeerDetail(peer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contacts_title),
        elevation: 0,
        automaticallyImplyLeading: !MobileShellScope.isActive(context),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            position: PopupMenuPosition.under,
            onSelected: (value) {
              switch (value) {
                case 'agent':
                  if (widget.embedded && widget.onAddAgentInstance != null) {
                    widget.onAddAgentInstance!();
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AddAgentInstanceScreen(),
                      ),
                    );
                  }
                case 'device':
                  _startPeerPairing();
                case 'group':
                  if (widget.onCreateGroup != null) {
                    widget.onCreateGroup!();
                  } else {
                    _createGroup();
                  }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'agent',
                child: Row(
                  children: [
                    const Icon(Icons.smart_toy_outlined, size: 22),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.home_addAgentInstance)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'device',
                child: Text(l10n.contacts_addPairingDevice),
              ),
              PopupMenuItem(
                value: 'group',
                child: Text(l10n.home_createGroup),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildSearchBar(l10n),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _reload(),
                    child: _buildSectionList(l10n),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: l10n.common_search,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _searchController.clear(),
                ),
          isDense: true,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildSectionList(AppLocalizations l10n) {
    final view = _view;
    if (view == null) return _buildSkeleton();

    final groups = _filteredGroups;
    final devices = _matchingDevices(view.devices);

    if (_query.isNotEmpty && devices.isEmpty && groups.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 72),
          Text(
            l10n.contacts_noSearchResults,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
        ],
      );
    }

    final children = <Widget>[
      if (view.hasSession && view.host != null && !view.hostOnline)
        _buildOfflineBanner(l10n),
      if (!view.hasSession)
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(l10n.contacts_noHost),
          onTap: () => Navigator.of(context).pushNamed(
            isDesktopPlatform ? '/host-setup' : '/pouch',
          ),
        )
      else ...[
        for (final device in devices)
          Opacity(
            opacity: device.isHost || view.hostOnline ? 1 : 0.45,
            child: Column(
              children: _deviceRows(device, view, l10n),
            ),
          ),
        if (view.rosterFailed)
          ListTile(
            title: Text(l10n.contacts_listFailed),
            onTap: () => _directory.refresh(),
          ),
      ],
      _buildSectionHeader(
        section: _ContactsSection.groups,
        title: l10n.contacts_groups,
        count: groups.length,
        icon: Icons.group_outlined,
        iconColor: const Color(0xFF07C160),
      ),
      if (_expanded.contains(_ContactsSection.groups))
        ..._buildGroupChildren(groups, l10n),
      const SizedBox(height: 24),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
  }

  Widget _buildSkeleton() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOfflineBanner(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.cloud_off_outlined, color: colorScheme.onErrorContainer),
        title: Text(
          l10n.hostOffline_banner,
          style: TextStyle(color: colorScheme.onErrorContainer),
        ),
        onTap: _reconnectHost,
      ),
    );
  }

  List<ContactDevice> _matchingDevices(List<ContactDevice> devices) {
    if (_query.isEmpty) return devices;
    final other = _view?.otherAgents ?? const <Agent>[];
    return devices.where((device) {
      if (device.peer.deviceName.toLowerCase().contains(_query)) return true;
      if (_matchingAgents(device.agents).isNotEmpty) return true;
      return device.isHost && _matchingAgents(other).isNotEmpty;
    }).toList();
  }

  List<Widget> _deviceRows(
    ContactDevice device,
    ContactsView view,
    AppLocalizations l10n,
  ) {
    final agents = _matchingAgents(device.agents);
    final extras =
        device.isHost ? _matchingAgents(view.otherAgents) : const <Agent>[];
    final visibleAgents = [...agents, ...extras];
    final expanded = _expandedPeerIds.contains(device.peer.id) ||
        (_query.isNotEmpty && visibleAgents.isNotEmpty);
    return [
      _buildPeerFoldHeader(
        device.peer,
        l10n,
        agents: visibleAgents,
        isHost: device.isHost,
        thisDevice: device.isThisDevice,
        online: device.isHost ? view.hostOnline : device.online,
        statusText: device.isHost ? _hostStatus(view, l10n) : null,
        onStatusTap: device.isHost && !view.hostOnline ? _reconnectHost : null,
      ),
      if (expanded) ...[
        ...agents.map(_buildAgentTile),
        if (extras.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: _childIndent, top: 4),
            child: Text(
              l10n.contacts_other,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
          ...extras.map(_buildAgentTile),
        ],
        if (device.isHost && _query.isEmpty)
          ListTile(
            contentPadding: const EdgeInsets.only(left: _childIndent, right: 16),
            leading: const Icon(Icons.add, size: 20),
            title: Text(l10n.home_addAgentInstance),
            onTap: _addAgent,
          ),
      ],
    ];
  }

  String _hostStatus(ContactsView view, AppLocalizations l10n) {
    if (!view.hostOnline) return l10n.contacts_offlineReconnect;
    return l10n.home_statusOnline;
  }

  Future<void> _reconnectHost() async {
    await _directory.reconnectHost();
  }

  void _addAgent() {
    if (widget.embedded && widget.onAddAgentInstance != null) {
      widget.onAddAgentInstance!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AddAgentInstanceScreen(),
      ),
    );
  }

  Widget _buildSectionHeader({
    required _ContactsSection section,
    required String title,
    required int count,
    required IconData icon,
    required Color iconColor,
  }) {
    final expanded = _expanded.contains(section);
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => _toggleSection(section),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.chevron_right,
                size: _chevronSize,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: _chevronGap),
            Container(
              width: _avatarSize,
              height: _avatarSize,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleTag(
    String label, {
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }

  /// Device row: chevron + device icon + name; tap toggles fold (mobile) or fold + detail (desktop).
  Widget _buildPeerFoldHeader(
    PairedPeer peer,
    AppLocalizations l10n, {
    required List<Agent> agents,
    String? statusText,
    bool isHost = false,
    bool thisDevice = false,
    bool? online,
    VoidCallback? onStatusTap,
  }) {
    final isConnected = online ?? peer.state == PeerConnectionState.connected;
    final expanded = _expandedPeerIds.contains(peer.id) ||
        (_query.isNotEmpty && agents.isNotEmpty);
    final agentCount = agents.length;
    final status = statusText ??
        peer.state.listStatusLabel(l10n, showE2eWhenConnected: true);
    final selected = widget.selectedContactId == peer.id;
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _onPeerTap(peer),
        onLongPress: widget.embedded ? null : () => _showPeerActions(peer),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  Icons.chevron_right,
                  size: _chevronSize,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: _chevronGap),
              Stack(
                children: [
                  PeerDeviceIcon(
                    peer: peer,
                    size: _avatarSize,
                    borderRadius: 8,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isConnected ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            peer.deviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (isHost) ...[
                          const SizedBox(width: 6),
                          _roleTag(
                            l10n.contacts_host,
                            background: colorScheme.tertiaryContainer,
                            foreground: colorScheme.onTertiaryContainer,
                          ),
                        ],
                        if (thisDevice) ...[
                          const SizedBox(width: 6),
                          _roleTag(
                            l10n.contacts_thisDevice,
                            background: colorScheme.primaryContainer,
                            foreground: colorScheme.onPrimaryContainer,
                          ),
                        ],
                      ],
                    ),
                    GestureDetector(
                      onTap: onStatusTap,
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isConnected ? Colors.green : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (agentCount > 0)
                Text(
                  '$agentCount',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              if (!widget.embedded) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    Icons.info_outline,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: l10n.peerSettings_title,
                  onPressed: () => _openPeerDetail(peer),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupChildren(List<Channel> groups, AppLocalizations l10n) {
    if (groups.isEmpty) {
      if (_query.isNotEmpty) return const [];
      return [
        _buildEmptyHint(
          icon: Icons.group_outlined,
          message: l10n.contacts_noGroups,
          actionLabel: l10n.home_createGroup,
          onAction: _createGroup,
        ),
      ];
    }
    return groups.map(_buildGroupTile).toList();
  }

  Widget _buildEmptyHint({
    required IconData icon,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    double indent = _childIndent,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(indent, 8, 16, 16),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(actionLabel, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _createGroup() async {
    if (widget.onCreateGroup != null) {
      widget.onCreateGroup!();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const CreateGroupScreen(),
      ),
    );
    if (mounted) _reload();
  }

  Widget _buildAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final isOnline = agent.status.isOnline;
    final displayName = SheService.isSheIdentity(agent.id, agent.metadata)
        ? SheService.resolveDisplayName(agent.name, l10n.she_name)
        : agent.name;

    final selected = widget.selectedContactId == agent.id;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: selected,
      selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
      // 与父节点（设备 / 分区）头像左对齐，不再额外缩进。
      contentPadding: const EdgeInsets.only(left: _childIndent, right: 16),
      leading: Stack(
        children: [
          Container(
            width: _avatarSize,
            height: _avatarSize,
            decoration: BoxDecoration(
              color: AppColors.avatarPlateFor(Theme.of(context).brightness),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: AvatarImage(
              avatar: agent.avatar,
              size: _avatarSize,
              borderRadius: 8,
              fallback: Text(
                agent.name.isNotEmpty ? agent.name[0] : 'A',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isOnline ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: agent.bio != null && agent.bio!.isNotEmpty
          ? Text(
              agent.bio!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            )
          : Text(
              isOnline ? l10n.home_statusOnline : l10n.home_statusOffline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isOnline ? Colors.green : Colors.grey,
              ),
            ),
      onTap: () => _openAgentDetail(agent),
    );
  }

  Widget _buildGroupTile(Channel group) {
    final l10n = AppLocalizations.of(context);
    final memberCount = group.members.where((m) => m.id != 'user').length;
    final selected = widget.selectedContactId == group.id;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: selected,
      selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.only(left: _childIndent, right: 16),
      leading: Container(
        width: _avatarSize,
        height: _avatarSize,
        decoration: BoxDecoration(
          color: AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.group, size: 20, color: AppColors.primary),
      ),
      title: Text(
        group.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        group.description?.isNotEmpty == true
            ? group.description!
            : l10n.contacts_memberCount(memberCount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
      ),
      onTap: () => _openGroupDetail(group),
    );
  }

  Future<void> _openAgentDetail(Agent agent) async {
    final remoteAgent = await _databaseService.getRemoteAgentById(agent.id);
    if (remoteAgent == null || !mounted) return;

    if (widget.onAgentSelected != null) {
      widget.onAgentSelected!(remoteAgent);
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteAgentDetailScreen(agent: remoteAgent),
      ),
    );
    _reload();
  }

  Future<void> _openGroupDetail(Channel group) async {
    if (widget.onGroupSelected != null) {
      widget.onGroupSelected!(group);
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupDetailScreen(channel: group),
      ),
    );
    _reload();
  }

  Future<void> _showPeerActions(PairedPeer peer) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final sheetL10n = AppLocalizations.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: Text(sheetL10n.peerSettings_title),
                onTap: () => Navigator.pop(ctx, 'settings'),
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: Text(sheetL10n.peerList_editAlias),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              ListTile(
                leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                title: Text(
                  sheetL10n.peerSettings_deletePairing,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (action == 'settings') {
      await _openPeerDetail(peer);
    } else if (action == 'rename') {
      await _renamePeer(peer);
    } else if (action == 'delete') {
      await _deletePeer(peer);
    }
  }

  Future<void> _renamePeer(PairedPeer peer) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final dialogL10n = AppLocalizations.of(ctx);
        final controller = TextEditingController(text: peer.deviceName);
        return AlertDialog(
          title: Text(dialogL10n.peerList_editAlias),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: dialogL10n.peerSettings_editAliasHint,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(dialogL10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(dialogL10n.common_save),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != peer.deviceName) {
      await PeerStorageService().updateDeviceName(peer.id, newName);
      _reload();
    }
  }

  Future<void> _deletePeer(PairedPeer peer) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dialogL10n = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(dialogL10n.peerSettings_deletePairing),
          content: Text(dialogL10n.peerSettings_deleteConfirm(peer.deviceName)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dialogL10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(dialogL10n.common_delete),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await PeerConnectionManager.instance.removePeer(peer.id);
      _reload();
    }
  }

  Future<void> _startPeerPairing() async {
    if (widget.onPairDevice != null) {
      widget.onPairDevice!();
      return;
    }
    // 通讯录「添加配对设备」：移动端进「它连我」等人扫；桌面直接进输入配对信息。
    final peer = isDesktopPlatform
        ? await PeerManualInputScreen.show(context)
        : await PeerPairingScreen.show(
            context,
            initialTab: PeerPairingTab.beConnected,
          );
    if (peer != null && mounted) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.peerList_pairedSuccess(peer.deviceName))),
      );
      _reload();
    }
  }

  Future<void> _openPeerDetail(PairedPeer peer) async {
    if (widget.onPeerSelected != null) {
      widget.onPeerSelected!(peer);
      return;
    }
    await PeerSettingsScreen.show(context, peer);
    if (mounted) _reload();
  }
}
