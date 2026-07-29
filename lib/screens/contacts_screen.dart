import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/widgets/peer_device_icon.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/she_service.dart';
import '../services/logger_service.dart';
import '../widgets/avatar_image.dart';
import '../models/remote_agent.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';

/// WeChat-style contacts screen with collapsible sections.
/// Order: each paired device (foldable, with peer agents) → Group Chats → Local.
///
/// When [embedded] is true (desktop middle column), selection callbacks open
/// details in the parent right panel instead of pushing a new route.
class ContactsScreen extends StatefulWidget {
  final bool embedded;
  final String? selectedContactId;
  final ValueChanged<RemoteAgent>? onAgentSelected;
  final ValueChanged<Channel>? onGroupSelected;
  final ValueChanged<PairedPeer>? onPeerSelected;
  final VoidCallback? onAddAgent;
  final VoidCallback? onCreateGroup;
  final VoidCallback? onPairDevice;

  const ContactsScreen({
    super.key,
    this.embedded = false,
    this.selectedContactId,
    this.onAgentSelected,
    this.onGroupSelected,
    this.onPeerSelected,
    this.onAddAgent,
    this.onCreateGroup,
    this.onPairDevice,
  });

  @override
  State<ContactsScreen> createState() => ContactsScreenState();
}

enum _ContactsSection { groups, local }

class ContactsScreenState extends State<ContactsScreen> {
  /// 折叠箭头列宽 + 间距，使子项头像与父节点头像左对齐。
  static const double _rowPadH = 12;
  static const double _chevronSize = 20;
  static const double _chevronGap = 4;
  static const double _avatarSize = 36;
  static const double _childIndent =
      _rowPadH + _chevronSize + _chevronGap; // 对齐父节点头像

  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  final TextEditingController _searchController = TextEditingController();

  List<Agent> _agents = [];
  List<Channel> _groups = [];
  List<PairedPeer> _peers = [];
  bool _isLoading = true;
  String _query = '';

  final Set<_ContactsSection> _expanded = {
    _ContactsSection.groups,
    _ContactsSection.local,
  };

  /// Peer ids whose nested agent list is expanded.
  final Set<String> _expandedPeerIds = {};

  Future<void> reload() => _loadData();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final next = _searchController.text.trim().toLowerCase();
      if (next != _query) {
        setState(() => _query = next);
      }
    });
    _loadData();
  }

  @override
  void dispose() {
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
        _peers.any((p) => p.id == selected)) {
      _expandedPeerIds.add(selected);
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final agents = await _apiService.getAgents();
      final allChannels = await _databaseService.getAllChannels();
      final groups = allChannels
          .where((c) => c.isGroup && c.parentGroupId == null)
          .toList();

      List<PairedPeer> peers = [];
      try {
        await PeerConnectionManager.instance.start();
        peers = await PeerConnectionManager.instance.getAllPeers();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _agents = agents;
          _groups = groups;
          _peers = peers;
          _isLoading = false;
        });
      }
    } catch (e) {
      LoggerService().error('Failed to load contacts data', tag: 'Contacts', error: e);
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Set<String> get _pairedPeerIds => _peers.map((p) => p.id).toSet();

  List<Agent> _agentsForPeer(String peerId) {
    final list = _agents
        .where((a) => a.isPeerAgent && a.sourcePeerId == peerId)
        .toList();
    if (_query.isEmpty) return list;
    return list.where(_agentMatchesQuery).toList();
  }

  List<Agent> get _localAgents {
    final paired = _pairedPeerIds;
    final list = _agents.where((a) {
      // 本机：非 peer agent；若 peer 已解配则暂挂在本机以免丢失入口。
      if (!a.isPeerAgent) return true;
      final src = a.sourcePeerId;
      return src == null || !paired.contains(src);
    }).toList();
    if (_query.isEmpty) return list;
    return list.where(_agentMatchesQuery).toList();
  }

  bool _agentMatchesQuery(Agent a) {
    final name = a.name.toLowerCase();
    final bio = a.bio?.toLowerCase() ?? '';
    return name.contains(_query) || bio.contains(_query);
  }

  List<PairedPeer> get _filteredPeers {
    if (_query.isEmpty) return _peers;
    return _peers.where((p) {
      if (p.deviceName.toLowerCase().contains(_query)) return true;
      return _agentsForPeer(p.id).isNotEmpty;
    }).toList();
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
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            onSelected: (value) {
              switch (value) {
                case 'device':
                  if (widget.onPairDevice != null) {
                    widget.onPairDevice!();
                  } else {
                    _startPeerPairing();
                  }
                case 'group':
                  if (widget.onCreateGroup != null) {
                    widget.onCreateGroup!();
                  } else {
                    _createGroup();
                  }
                case 'agent':
                  if (widget.onAddAgent != null) {
                    widget.onAddAgent!();
                  } else {
                    _addAgent();
                  }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'device',
                child: Text(l10n.contacts_addPairingDevice),
              ),
              PopupMenuItem(
                value: 'group',
                child: Text(l10n.home_createGroup),
              ),
              PopupMenuItem(
                value: 'agent',
                child: Text(l10n.home_addAgent),
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
                    onRefresh: _loadData,
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
    final peers = _filteredPeers;
    final groups = _filteredGroups;
    final localAgents = _localAgents;

    final children = <Widget>[
      // Each paired device is its own foldable row (with nested peer agents).
      if (peers.isEmpty)
        _buildEmptyHint(
          icon: Icons.devices_other,
          message: l10n.contacts_noPeers,
          actionLabel: l10n.contacts_startPairing,
          onAction: _startPeerPairing,
          indent: 16,
        )
      else
        for (final peer in peers) ...[
          _buildPeerFoldHeader(peer, l10n),
          if (_expandedPeerIds.contains(peer.id) ||
              (_query.isNotEmpty && _agentsForPeer(peer.id).isNotEmpty))
            ..._agentsForPeer(peer.id).map(
              (a) => _buildAgentTile(a),
            ),
        ],

      // Group chats
      _buildSectionHeader(
        section: _ContactsSection.groups,
        title: l10n.contacts_groups,
        count: groups.length,
        icon: Icons.group_outlined,
        iconColor: const Color(0xFF07C160),
      ),
      if (_expanded.contains(_ContactsSection.groups))
        ..._buildGroupChildren(groups, l10n),

      // Local agents (本机)
      _buildSectionHeader(
        section: _ContactsSection.local,
        title: l10n.contacts_agents,
        count: localAgents.length,
        icon: Icons.smartphone_outlined,
        iconColor: AppColors.primary,
      ),
      if (_expanded.contains(_ContactsSection.local))
        ..._buildLocalAgentChildren(localAgents, l10n),
      const SizedBox(height: 24),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
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

  /// Device row: chevron + device icon + name; tap toggles fold (mobile) or fold + detail (desktop).
  Widget _buildPeerFoldHeader(PairedPeer peer, AppLocalizations l10n) {
    final isConnected = peer.state == PeerConnectionState.connected;
    final expanded = _expandedPeerIds.contains(peer.id) ||
        (_query.isNotEmpty && _agentsForPeer(peer.id).isNotEmpty);
    final agentCount = _agents
        .where((a) => a.isPeerAgent && a.sourcePeerId == peer.id)
        .length;
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
                    Text(
                      peer.deviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      peer.state.listStatusLabel(l10n, showE2eWhenConnected: true),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isConnected ? Colors.green : Colors.grey,
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

  List<Widget> _buildLocalAgentChildren(
    List<Agent> agents,
    AppLocalizations l10n,
  ) {
    if (agents.isEmpty) {
      return [
        _buildEmptyHint(
          icon: Icons.smart_toy_outlined,
          message: l10n.contacts_noAgents,
          actionLabel: l10n.home_addAgent,
          onAction: _addAgent,
        ),
      ];
    }
    return agents.map((a) => _buildAgentTile(a)).toList();
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

  Future<void> _addAgent() async {
    if (widget.onAddAgent != null) {
      widget.onAddAgent!();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AddRemoteAgentScreen(),
      ),
    );
    if (mounted) _loadData();
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
    if (mounted) _loadData();
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
              color: Colors.grey[200],
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
    _loadData();
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
    _loadData();
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
      _loadData();
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
      _loadData();
    }
  }

  Future<void> _startPeerPairing() async {
    if (widget.onPairDevice != null) {
      widget.onPairDevice!();
      return;
    }
    final peer = await PeerPairingScreen.show(context);
    if (peer != null && mounted) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.peerList_pairedSuccess(peer.deviceName))),
      );
      _loadData();
    }
  }

  Future<void> _openPeerDetail(PairedPeer peer) async {
    if (widget.onPeerSelected != null) {
      widget.onPeerSelected!(peer);
      return;
    }
    await PeerSettingsScreen.show(context, peer);
    if (mounted) _loadData();
  }
}
