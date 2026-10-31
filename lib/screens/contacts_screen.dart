import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/widgets/peer_device_icon.dart';
import '../peer/screens/add_agent_instance_screen.dart';
import '../utils/platform_utils.dart';
import '../peer/peer_device_actions.dart';
import '../services/chat_navigation_service.dart';
import '../services/contacts_directory.dart';
import '../services/contacts_rows.dart';
import '../services/local_database_service.dart';
import '../services/remote_agent_service.dart';
import '../services/she_service.dart';
import '../services/logger_service.dart';
import '../service_locator.dart';
import '../widgets/add_entry_menu.dart';
import '../widgets/avatar_image.dart';
import '../widgets/contacts_tab_switcher.dart';
import '../widgets/mobile_shell_scope.dart';
import '../models/remote_agent.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';
import 'create_group_screen.dart';

/// 通讯录。两个分段：[ContactsTab.people] 用来找人聊天（群聊 + Agent），
/// [ContactsTab.devices] 用来管设备（主机 / 工作节点 / 客户端）。
///
/// 原来是一棵「分区 → 设备 → Agent」三层折叠树，最常用的 Agent 藏在第三层，
/// 客户端这种设备管理信息又混在联系人里。现在两边各自是一层列表。
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

  /// 添加 Agent 实例。从工作节点行进来时带上节点指纹，主机为 null。
  final ValueChanged<String?>? onAddAgentInstance;

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

/// 长按 / 右键菜单里的一项。
class _MenuAction {
  const _MenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.danger = false,
    this.enabled = true,
  });

  final String value;
  final String label;
  final IconData icon;
  final bool danger;
  final bool enabled;
}

class ContactsScreenState extends State<ContactsScreen> {
  static const double _avatarSize = 36;
  static const double _childIndent = 16;

  final LocalDatabaseService _databaseService = LocalDatabaseService();
  final TextEditingController _searchController = TextEditingController();
  late final ContactsDirectory _directory;

  ContactsView? _view;
  List<Channel> _groups = [];
  bool _isLoading = true;
  bool _reconnecting = false;
  String _query = '';
  ContactsTab _tab = ContactsTab.people;

  /// 一次配对的两边会共用 peer id，选中态要按行区分。
  String? _selectedRowKey;

  /// 桌面端键盘上下键的位置，指向 [_entries] 里可选中的行。
  int _focusIndex = -1;
  final FocusNode _listFocusNode = FocusNode();

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
        setState(() {
          _query = next;
          _focusIndex = -1;
        });
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
      });
    });
    _reload(quiet: cached != null);
  }

  @override
  void dispose() {
    _directorySub?.cancel();
    _listFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload({bool quiet = false}) async {
    // 手上已经有目录快照就一律静默：`_isLoading` 会把整个 body 换成骨架屏，
    // 连 RefreshIndicator 一起卸掉，下拉刷新、从详情返回都会看到整页闪一下。
    final silent = quiet || _view != null;
    if (!silent && mounted) setState(() => _isLoading = true);
    // 群聊和通讯录互不依赖，一起发起，别让页面顺序等两轮。
    // 目录的失败处理先挂上，避免它比群聊查询更早失败时成为未处理异步错误。
    final directoryFuture = _directory.refresh().catchError((Object e) {
      LoggerService()
          .error('Failed to refresh contacts', tag: 'Contacts', error: e);
    });
    try {
      final groups = await _databaseService.getTopLevelGroups();
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      LoggerService().error('Failed to load groups', tag: 'Contacts', error: e);
    }
    try {
      await directoryFuture;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ==================== 数据 ====================

  List<ContactsRow> _entriesFor(AppLocalizations l10n) {
    final view = _view;
    if (view == null) return const [];
    return ContactsRows.build(
      view: view,
      groups: _groups,
      query: _query,
      showDevices: _tab == ContactsTab.devices,
      l10n: l10n,
    );
  }

  // ==================== 页面 ====================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contacts_title),
        elevation: 0,
        automaticallyImplyLeading: !MobileShellScope.isActive(context),
        actions: [
          PopupMenuButton<AddEntryAction>(
            icon: const Icon(Icons.add),
            position: PopupMenuPosition.under,
            onSelected: (action) {
              AddEntryMenu.run(
                context,
                action,
                embedded: widget.embedded,
                onAddAgentInstance: () => _addAgent(),
                onCreateGroup: widget.onCreateGroup ?? _createGroup,
                onPairDevice: widget.onPairDevice,
                onPaired: (peer) {
                  if (!mounted) return;
                  final l10n = AppLocalizations.of(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content:
                          Text(l10n.peerList_pairedSuccess(peer.deviceName)),
                    ),
                  );
                  _reload();
                },
                afterPushed: () {
                  if (mounted) _reload();
                },
              );
            },
            itemBuilder: (context) => AddEntryMenu.items(
              AppLocalizations.of(context),
              showScan: AddEntryMenu.supportsScan,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(l10n),
          ContactsTabSwitcher(
            tab: _tab,
            onChanged: (next) => setState(() {
              _tab = next;
              _focusIndex = -1;
            }),
          ),
          _buildStatusBanner(l10n),
          Expanded(child: _buildBody(l10n)),
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// 主机离线的横幅。放在列表外面，滚多远都看得见，也是唯一的重连入口。
  Widget _buildStatusBanner(AppLocalizations l10n) {
    final view = _view;
    if (view == null) return const SizedBox.shrink();
    if (view.hasSession && view.host != null && !view.hostOnline) {
      final colorScheme = Theme.of(context).colorScheme;
      return Material(
        color: colorScheme.errorContainer,
        child: ListTile(
          dense: true,
          leading: Icon(
            Icons.cloud_off_outlined,
            color: colorScheme.onErrorContainer,
          ),
          title: Text(
            l10n.hostOffline_banner,
            style: TextStyle(color: colorScheme.onErrorContainer),
          ),
          trailing: _reconnecting
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onErrorContainer,
                  ),
                )
              : TextButton(
                  onPressed: _reconnectHost,
                  child: Text(l10n.contacts_reconnect),
                ),
        ),
      );
    }
    if (view.rosterFailed && _tab == ContactsTab.devices) {
      final colorScheme = Theme.of(context).colorScheme;
      return Material(
        color: colorScheme.surfaceContainerHighest,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.sync_problem_outlined),
          title: Text(l10n.contacts_listFailed),
          trailing: TextButton(
            onPressed: () => _reload(),
            child: Text(l10n.contacts_rosterRetry),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBody(AppLocalizations l10n) {
    final view = _view;
    if (view == null) {
      return RefreshIndicator(
        onRefresh: () => _reload(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_isLoading)
              ..._buildSkeletonRows()
            else
              const SizedBox(height: 32),
          ],
        ),
      );
    }

    if (!view.hasSession) return _buildNoSession(l10n);

    final entries = _entriesFor(l10n);
    if (entries.isEmpty) {
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

    return RefreshIndicator(
      onRefresh: () => _reload(),
      child: Focus(
        focusNode: _listFocusNode,
        onKeyEvent: _onListKey,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index == entries.length) return const SizedBox(height: 24);
            return _buildRow(l10n, entries, index);
          },
        ),
      ),
    );
  }

  Widget _buildNoSession(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 48, color: colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              l10n.contacts_noSessionTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.contacts_noSessionBody,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              // 走根 Navigator：主机流程内部靠命名路由跳转，嵌套导航认不得。
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .pushNamed(isDesktopPlatform ? '/host-setup' : '/pouch'),
              icon: const Icon(Icons.dns_outlined),
              label: Text(l10n.contacts_connectHost),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSkeletonRows() => [
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
      ];

  // ==================== 行 ====================

  Widget _buildRow(
      AppLocalizations l10n, List<ContactsRow> entries, int index) {
    final entry = entries[index];
    if (index == _focusIndex && entry.isSelectable) {
      final colorScheme = Theme.of(context).colorScheme;
      return ColoredBox(
        color: colorScheme.primary.withValues(alpha: 0.06),
        child: _buildRowContent(l10n, entry),
      );
    }
    return _buildRowContent(l10n, entry);
  }

  Widget _buildRowContent(AppLocalizations l10n, ContactsRow entry) {
    switch (entry.kind) {
      case ContactsRowKind.header:
        return _buildSectionHeader(entry);
      case ContactsRowKind.groupHint:
        return _buildGroupsEmptyHint(l10n);
      case ContactsRowKind.device:
        return _buildDeviceTile(l10n, entry.device!);
      case ContactsRowKind.agent:
        return _buildAgentTile(l10n, entry.agent!, nodeName: entry.parentName);
      case ContactsRowKind.group:
        return _buildGroupTile(l10n, entry.group!);
    }
  }

  Widget _buildSectionHeader(ContactsRow entry) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (entry.countLabel != null)
            Text(
              entry.countLabel!,
              style:
                  TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  /// 群聊为空时的引导。文案和按钮由页面给，构造列表时不必带上回调。
  Widget _buildGroupsEmptyHint(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_childIndent, 4, 16, 8),
      child: Row(
        children: [
          Icon(Icons.group_outlined, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.contacts_noGroups,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          ),
          TextButton(
            onPressed: _createGroup,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              l10n.home_createGroup,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentTile(
    AppLocalizations l10n,
    Agent agent, {
    String? nodeName,
  }) {
    final isOnline = agent.status.isOnline;
    final displayName = SheService.isSheIdentity(agent.id, agent.metadata)
        ? SheService.resolveDisplayName(agent.name, l10n.she_name)
        : agent.name;
    final selected = widget.selectedContactId == agent.id;
    final colorScheme = Theme.of(context).colorScheme;
    final onlineColor = AppColors.onlineFor(Theme.of(context).brightness);

    final bio = agent.bio?.trim() ?? '';
    final statusText =
        isOnline ? l10n.home_statusOnline : l10n.home_statusOffline;
    // 状态始终显示，简介拼在后面：原来有简介就看不到在线状态了。
    final subtitle = bio.isEmpty ? statusText : '$statusText · $bio';

    return _withSecondary(
      ListTile(
        selected: selected,
        selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
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
                  color: isOnline ? onlineColor : Colors.grey,
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
        subtitle: Text(
          nodeName == null ? subtitle : '$nodeName · $subtitle',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        onTap: () => _onAgentTap(agent),
      ),
      onLongPress: () => _showAgentMenu(agent),
      onSecondary: (d) => _showAgentMenu(agent, at: d.globalPosition),
      onDoubleTap: widget.embedded ? () => _openAgentConversation(agent) : null,
    );
  }

  /// 列表行统一的右键 / 长按包裹。ListTile 自己没有 onSecondaryTapUp。
  Widget _withSecondary(
    Widget child, {
    VoidCallback? onLongPress,
    ValueChanged<TapUpDetails>? onSecondary,
    VoidCallback? onDoubleTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      onSecondaryTapUp: onSecondary,
      // 桌面端单击进详情，双击直接开聊。
      onDoubleTap: onDoubleTap,
      child: child,
    );
  }

  Widget _buildGroupTile(AppLocalizations l10n, Channel group) {
    final memberCount = group.members.where((m) => m.id != 'user').length;
    final selected = widget.selectedContactId == group.id;
    final colorScheme = Theme.of(context).colorScheme;

    return _withSecondary(
      ListTile(
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
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        onTap: () => _onGroupTap(group),
      ),
      onLongPress: () => _showGroupMenu(group),
      onSecondary: (d) => _showGroupMenu(group, at: d.globalPosition),
      onDoubleTap: widget.embedded ? () => _openGroupConversation(group) : null,
    );
  }

  Widget _buildDeviceTile(AppLocalizations l10n, ContactDevice device) {
    final peer = device.peer;
    final online = device.isHost ? (_view?.hostOnline ?? false) : device.online;
    final selected = _isDeviceSelected(device);
    final colorScheme = Theme.of(context).colorScheme;
    final onlineColor = AppColors.onlineFor(Theme.of(context).brightness);
    final agentCount = device.agents.length;

    final status = device.isHost
        ? (online ? l10n.home_statusOnline : l10n.contacts_offlineReconnect)
        : (device.section == ContactSection.worker && !device.online
            ? l10n.contacts_nodeOffline
            : peer.state.listStatusLabel(l10n, showE2eWhenConnected: true));

    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: _withSecondary(
        ListTile(
          contentPadding: const EdgeInsets.only(left: _childIndent, right: 16),
          leading: Stack(
            children: [
              PeerDeviceIcon(peer: peer, size: _avatarSize, borderRadius: 8),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: online ? onlineColor : Colors.grey,
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
          title: Row(
            children: [
              Flexible(
                child: Text(
                  peer.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
              if (device.isHost) ...[
                const SizedBox(width: 6),
                _roleTag(
                  l10n.contacts_host,
                  background: colorScheme.tertiaryContainer,
                  foreground: colorScheme.onTertiaryContainer,
                ),
              ],
              if (device.isThisDevice) ...[
                const SizedBox(width: 6),
                _roleTag(
                  l10n.contacts_thisDevice,
                  background: colorScheme.primaryContainer,
                  foreground: colorScheme.onPrimaryContainer,
                ),
              ],
            ],
          ),
          subtitle: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: online ? onlineColor : colorScheme.onSurfaceVariant,
            ),
          ),
          trailing:
              agentCount > 0 && device.section != ContactSection.mobileClient
                  ? Text(
                      l10n.contacts_agentCount(agentCount),
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant),
                    )
                  : null,
          // 点击只做一件事：进详情。长按 / 右键才是管理操作。
          onTap: () => _onDeviceTap(device),
        ),
        onLongPress: () => _showDeviceMenu(device),
        onSecondary: (d) => _showDeviceMenu(device, at: d.globalPosition),
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

  // ==================== 操作 ====================

  bool _isDeviceSelected(ContactDevice device) {
    final selected = widget.selectedContactId;
    if (selected == null || selected != device.peer.id) return false;
    final matches =
        _view?.devices.where((item) => item.peer.id == selected).length ?? 0;
    if (matches <= 1) return true;
    return _selectedRowKey == device.rowKey;
  }

  /// 手机：单击直接进对话。桌面：单击进详情，菜单里的「发消息」才进对话。
  Future<void> _onAgentTap(Agent agent) async {
    if (widget.embedded) {
      await _openAgentDetail(agent);
      return;
    }
    await _openAgentConversation(agent);
  }

  Future<void> _openAgentConversation(Agent agent) async {
    final l10n = AppLocalizations.of(context);
    final name = SheService.isSheIdentity(agent.id, agent.metadata)
        ? SheService.resolveDisplayName(agent.name, l10n.she_name)
        : agent.name;
    await ChatNavigationService.instance.openAgentConversation(
      agentId: agent.id,
      agentName: name,
      agentAvatar: agent.avatar,
    );
  }

  Future<void> _onGroupTap(Channel group) async {
    if (widget.embedded) {
      _openGroupDetail(group);
      return;
    }
    await _openGroupConversation(group);
  }

  Future<void> _openGroupConversation(Channel group) async {
    final channelId = await _databaseService
            .getLatestActiveGroupChannel(group.groupFamilyId) ??
        group.id;
    if (!mounted) return;
    await ChatNavigationService.instance.openChannel(channelId: channelId);
  }

  Future<void> _onDeviceTap(ContactDevice device) async {
    _selectedRowKey = device.rowKey;
    await _openPeerDetail(device);
  }

  Future<void> _reconnectHost() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    final ok = await _directory.reconnectHost();
    if (!mounted) return;
    setState(() => _reconnecting = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).contacts_reconnectFailed),
        ),
      );
    }
  }

  void _addAgent({String? nodeId}) {
    if (widget.embedded && widget.onAddAgentInstance != null) {
      widget.onAddAgentInstance!(nodeId);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddAgentInstanceScreen(presetNodeId: nodeId),
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

  Future<void> _openPeerDetail(ContactDevice device) async {
    if (widget.onPeerSelected != null) {
      widget.onPeerSelected!(device.peer);
      return;
    }
    await PeerSettingsScreen.show(context, device.peer, device: device);
    if (mounted) _reload();
  }

  // ==================== 菜单 ====================

  Future<void> _showAgentMenu(Agent agent, {Offset? at}) async {
    final l10n = AppLocalizations.of(context);
    final hidden = await _isAgentHidden(agent);
    final action = await _showMenu(l10n, at: at, [
      _MenuAction(
        value: 'chat',
        label: l10n.contacts_actionSendMessage,
        icon: Icons.chat_bubble_outline,
      ),
      _MenuAction(
        value: 'detail',
        label: l10n.contacts_actionViewDetail,
        icon: Icons.info_outline,
      ),
      _MenuAction(
        value: hidden ? 'show' : 'hide',
        label: hidden
            ? l10n.contacts_actionShowOnApp
            : l10n.contacts_actionHideOnApp,
        icon:
            hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ),
    ]);
    if (action == null || !mounted) return;
    if (action == 'chat') {
      await _openAgentConversation(agent);
    } else if (action == 'detail') {
      await _openAgentDetail(agent);
    } else if (action == 'hide' || action == 'show') {
      await _setAgentHidden(agent, !hidden);
    }
  }

  Future<void> _showGroupMenu(Channel group, {Offset? at}) async {
    final l10n = AppLocalizations.of(context);
    final action = await _showMenu(l10n, at: at, [
      _MenuAction(
        value: 'chat',
        label: l10n.contacts_actionEnterGroup,
        icon: Icons.chat_bubble_outline,
      ),
      _MenuAction(
        value: 'detail',
        label: l10n.contacts_actionGroupDetail,
        icon: Icons.info_outline,
      ),
    ]);
    if (action == null || !mounted) return;
    if (action == 'chat') {
      await _openGroupConversation(group);
    } else if (action == 'detail') {
      await _openGroupDetail(group);
    }
  }

  Future<void> _showDeviceMenu(ContactDevice device, {Offset? at}) async {
    final l10n = AppLocalizations.of(context);
    final online = device.isHost ? (_view?.hostOnline ?? false) : device.online;
    final canHost = device.isHost || device.section == ContactSection.worker;
    final isUnlisted = device.peer.id.startsWith('node:');
    final action = await _showMenu(l10n, at: at, [
      _MenuAction(
        value: 'detail',
        label: l10n.peerSettings_title,
        icon: Icons.settings_outlined,
      ),
      _MenuAction(
        value: 'rename',
        label: l10n.peerList_editAlias,
        icon: Icons.edit,
      ),
      if (canHost)
        _MenuAction(
          value: 'addAgent',
          label: l10n.contacts_actionAddAgentHere,
          icon: Icons.add,
          enabled: online,
        ),
      // 名单没同步回来的节点行没有真正的配对记录，删了没意义。
      if (!isUnlisted)
        _MenuAction(
          value: 'delete',
          label: l10n.peerSettings_deletePairing,
          icon: Icons.delete_outline,
          danger: true,
        ),
    ]);
    if (action == null || !mounted) return;
    if (action == 'detail') {
      await _openPeerDetail(device);
    } else if (action == 'rename') {
      await PeerDeviceActions.rename(context, device.peer);
      if (mounted) _reload();
    } else if (action == 'addAgent') {
      _addAgent(nodeId: device.nodeId);
    } else if (action == 'delete') {
      await _deletePeer(device);
    }
  }

  /// 手机弹底部弹窗，桌面在鼠标位置弹菜单，两项共用同一份菜单定义。
  Future<String?> _showMenu(
    AppLocalizations l10n,
    List<_MenuAction> actions, {
    Offset? at,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (widget.embedded || isDesktopPlatform) {
      final target = at ?? Offset.zero;
      return showMenu<String>(
        context: context,
        position:
            RelativeRect.fromLTRB(target.dx, target.dy, target.dx, target.dy),
        items: [
          for (final action in actions)
            PopupMenuItem<String>(
              value: action.value,
              enabled: action.enabled,
              child: Row(
                children: [
                  Icon(
                    action.icon,
                    size: 20,
                    color: action.danger ? colorScheme.error : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    action.label,
                    style: action.danger
                        ? TextStyle(color: colorScheme.error)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                enabled: action.enabled,
                leading: Icon(
                  action.icon,
                  color: action.danger ? colorScheme.error : null,
                ),
                title: Text(
                  action.label,
                  style: action.danger
                      ? TextStyle(color: colorScheme.error)
                      : null,
                ),
                onTap: () => Navigator.pop(ctx, action.value),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> _isAgentHidden(Agent agent) async {
    final remote = await _databaseService.getRemoteAgentById(agent.id);
    return remote?.hiddenOnThisApp ?? false;
  }

  Future<void> _setAgentHidden(Agent agent, bool hidden) async {
    final remote = await _databaseService.getRemoteAgentById(agent.id);
    if (remote == null) return;
    try {
      await getIt<RemoteAgentService>().setVisibleOnApp(remote, !hidden);
    } catch (e) {
      LoggerService()
          .error('toggle agent visibility failed', tag: 'Contacts', error: e);
    }
    if (mounted) _reload();
  }

  Future<void> _deletePeer(ContactDevice device) async {
    final confirm = await PeerDeviceActions.confirmDelete(
      context,
      device.peer,
      isHost: device.isHost,
      isThisDevice: device.isThisDevice,
    );
    if (!confirm || !mounted) return;
    final removed = await PeerDeviceActions.delete(context, device.peer);
    if (!removed || !mounted) return;
    _reload();
  }

  // ==================== 键盘 ====================

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final entries = _entriesFor(AppLocalizations.of(context));
    final selectable = <int>[];
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isSelectable) selectable.add(i);
    }
    if (selectable.isEmpty) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final step = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final current = selectable.indexOf(_focusIndex);
      final next = current < 0
          ? (step > 0 ? 0 : selectable.length - 1)
          : (current + step).clamp(0, selectable.length - 1);
      setState(() => _focusIndex = selectable[next]);
      _scrollToIndex(selectable[next]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && _focusIndex >= 0) {
      _activate(entries[_focusIndex]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 键盘选中的行滚进视野。行高固定，按序号估算偏移就够了。
  void _scrollToIndex(int index) {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    const rowHeight = 60.0;
    final target = (index * rowHeight).clamp(0.0, position.maxScrollExtent);
    if (target < position.pixels ||
        target > position.pixels + position.viewportDimension - rowHeight) {
      position.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  void _activate(ContactsRow entry) {
    switch (entry.kind) {
      case ContactsRowKind.agent:
        unawaited(_openAgentConversation(entry.agent!));
        break;
      case ContactsRowKind.group:
        unawaited(_openGroupConversation(entry.group!));
        break;
      case ContactsRowKind.device:
        unawaited(_openPeerDetail(entry.device!));
        break;
      case ContactsRowKind.header:
      case ContactsRowKind.groupHint:
        break;
    }
  }
}
