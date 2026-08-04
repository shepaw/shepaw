import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'storage_space_screen.dart';
import '../widgets/agent_search_delegate.dart';
import '../widgets/shepaw_search_page.dart';
import '../widgets/avatar_image.dart';
import '../widgets/chat/session_unread_badge.dart';
import '../services/message_search_service.dart';
import '../services/she_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../providers/notification_provider.dart';
import '../models/conversation_selection.dart';
import '../models/conversation_list_entry.dart';
import '../controllers/conversation_list_controller.dart';
import '../service_locator.dart' show getIt;
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_chat_screen.dart';
import '../peer/widgets/peer_device_icon.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../widgets/drawer_swipe_detector.dart';
import 'package:provider/provider.dart';

/// 应用主页 - Telegram风格设计
class HomeScreen extends StatefulWidget {
  /// When true, the screen is embedded inside a desktop split-panel layout.
  /// Drawer, FAB and hamburger menu are hidden; conversation taps fire
  /// [onConversationSelected] instead of pushing a new route.
  final bool embedded;

  /// The currently selected conversation (used for highlight in embedded mode).
  final ConversationSelection? selectedConversation;

  /// Called when a conversation tile is tapped in embedded mode.
  final ValueChanged<ConversationSelection>? onConversationSelected;

  /// 桌面嵌入模式：标题栏添加菜单回调。
  final VoidCallback? onAddAgent;
  final VoidCallback? onCreateGroup;
  final VoidCallback? onPairDevice;

  const HomeScreen({
    Key? key,
    this.embedded = false,
    this.selectedConversation,
    this.onConversationSelected,
    this.onAddAgent,
    this.onCreateGroup,
    this.onPairDevice,
  }) : super(key: key);

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = getIt<LocalDatabaseService>();
  final ChatService _chatService = ChatService();
  late final ConversationListController _list;
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _addButtonKey = GlobalKey();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final MessageSearchService _messageSearchService;
  List<Channel> _searchChannelResults = [];
  List<MessageSearchResult> _searchMessageResults = [];
  List<PeerMessageSearchResult> _searchPeerMessageResults = [];
  bool _isEmbeddedSearching = false;
  Timer? _searchDebounce;

  // Convenience accessors for tiles (backed by ConversationListController).
  List<Agent> get _agents => _list.agents;
  List<Agent> get _filteredAgents => _list.filteredAgents;
  List<Channel> get _groupChannels => _list.groupChannels;
  List<PairedPeer> get _pairedPeers => _list.pairedPeers;
  List<ConversationListItem> get _sortedConversations => _list.entries;
  bool get _isLoading => _list.isLoading;
  Set<String> get _typingAgentIds => _list.typingAgentIds;
  Set<String> get _typingChannelIds => _list.typingChannelIds;
  Map<String, Map<String, dynamic>?> get _latestMessages => _list.latestMessages;
  Map<String, int> get _unreadCounts => _list.unreadCounts;
  Map<String, Map<String, dynamic>?> get _groupLatestMessages => _list.groupLatestMessages;
  Map<String, int> get _groupUnreadCounts => _list.groupUnreadCounts;
  Map<String, Set<String>> get _groupSessionChannelIds => _list.groupSessionChannelIds;
  Map<String, String> get _peerLatestContent => _list.peerLatestContent;
  Map<String, int> get _peerLatestTime => _list.peerLatestTime;
  Map<String, int> get _peerUnreadCounts => _list.peerUnreadCounts;

  /// Public accessor so DesktopHomeScreen can trigger a refresh via GlobalKey.
  void reloadAgents() => _list.refresh(silent: true);

  /// Public accessor for the current agents list (used by desktop sidebar search).
  List<Agent> get agents => _list.agents;

  @override
  void initState() {
    super.initState();
    _list = ConversationListController(
      apiService: _apiService,
      databaseService: _databaseService,
      chatService: _chatService,
    );
    _list.setActiveSelection(widget.selectedConversation);
    _list.addListener(_onListChanged);
    _list.attach();
    _messageSearchService = MessageSearchService(_databaseService);
    _list.refresh();
    _searchController.addListener(_onSearchChanged);
  }

  void _onListChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedConversation != oldWidget.selectedConversation) {
      _list.setActiveSelection(widget.selectedConversation);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifProvider = context.read<NotificationProvider>();
    _chatService.setNotificationProvider(notifProvider);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _list.removeListener(_onListChanged);
    _list.dispose();
    super.dispose();
  }

  Future<void> _loadAgents({bool silent = false}) => _list.refresh(silent: silent);

  /// After leaving a chat, force the draft listener to re-sort (WeChat-style bump).
  void _publishComposerDrafts() {
    if (!getIt.isRegistered<ComposerDraftService>()) return;
    getIt<ComposerDraftService>().publish();
  }

  /// 搜索过滤
  void _onSearchChanged() {
    if (widget.embedded) {
      setState(() {});
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _performEmbeddedSearch(_searchController.text.trim());
      });
      return;
    }
    _list.setSearchQuery(_searchController.text);
  }

  Future<void> _performEmbeddedSearch(String query) async {
    if (!widget.embedded) return;
    if (query.isEmpty) {
      _list.setSearchQuery('');
      setState(() {
        _searchChannelResults = [];
        _searchMessageResults = [];
        _searchPeerMessageResults = [];
        _isEmbeddedSearching = false;
      });
      return;
    }

    setState(() => _isEmbeddedSearching = true);
    _list.setSearchQuery(query);

    List<Channel> channelResults = [];
    List<MessageSearchResult> messageResults = [];
    List<PeerMessageSearchResult> peerMessageResults = [];
    try {
      final allChannels = await _databaseService.getAllChannels();
      final lowerQuery = query.toLowerCase();
      channelResults = allChannels.where((ch) {
        return ch.name.toLowerCase().contains(lowerQuery) ||
            (ch.description?.toLowerCase().contains(lowerQuery) ?? false);
      }).toList();
    } catch (_) {}
    try {
      messageResults = await _messageSearchService.searchMessages(
        query: query,
        limit: 20,
      );
    } catch (_) {}
    try {
      peerMessageResults = await PeerStorageService().searchMessages(
        query: query,
        limit: 20,
      );
    } catch (_) {}

    if (!mounted || _searchController.text.trim() != query) return;
    setState(() {
      _searchChannelResults = channelResults;
      _searchMessageResults = messageResults;
      _searchPeerMessageResults = peerMessageResults;
      _isEmbeddedSearching = false;
    });
  }

  /// Agent头像（右上角显示未读角标；待审时橙色角标）
  Widget _buildAgentAvatar(Agent agent, int unreadCount, {bool pendingApproval = false}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: AvatarImage(
            avatar: agent.avatar,
            size: 40,
            borderRadius: 10,
            fallback: Text(
              agent.name.isNotEmpty ? agent.name[0] : 'A',
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
        if (unreadCount > 0)
          AvatarUnreadBadgeOverlay(count: unreadCount)
        else if (pendingApproval)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.orange[700],
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 状态标签（在线/离线/思考中）
  Widget _buildStatusLabel(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final isTyping = _typingAgentIds.contains(agent.id);

    String statusText;
    Color statusColor;

    if (isTyping) {
      statusText = l10n.home_statusThinking;
      statusColor = Colors.orange;
    } else if (agent.status.isOnline) {
      statusText = l10n.home_statusOnline;
      statusColor = Colors.green;
    } else {
      statusText = l10n.home_statusOffline;
      statusColor = Colors.grey;
    }

    return Text(
      statusText,
      style: TextStyle(
        fontSize: 11,
        color: statusColor,
        fontWeight: FontWeight.w400,
      ),
    );
  }

  /// 格式化时间（微信风格）
  String _formatTime(String? createdAt) {
    if (createdAt == null) return '';
    final dateTime = DateTime.tryParse(createdAt);
    if (dateTime == null) return '';
    return _formatDateTime(dateTime);
  }

  String _formatDateTime(DateTime dateTime) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (messageDate == today) {
      // 今天：显示 HH:mm
      return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      return l10n.home_yesterday;
    } else if (now.difference(dateTime).inDays < 7) {
      final weekDays = [l10n.home_weekMon, l10n.home_weekTue, l10n.home_weekWed, l10n.home_weekThu, l10n.home_weekFri, l10n.home_weekSat, l10n.home_weekSun];
      return weekDays[dateTime.weekday - 1];
    } else if (dateTime.year == now.year) {
      return '${dateTime.month}/${dateTime.day}';
    } else {
      return '${dateTime.year}/${dateTime.month}/${dateTime.day}';
    }
  }

  String _agentDraftText(Agent agent) {
    if (!getIt.isRegistered<ComposerDraftService>()) return '';
    final service = getIt<ComposerDraftService>();
    final fromAgent =
        service.getDraft(ComposerDraftService.agentListKey(agent.id));
    if (fromAgent.isNotEmpty) return fromAgent;
    final channelId = _list.agentChannelId(agent.id);
    if (channelId == null) return '';
    return service.getDraft(channelId);
  }

  DateTime? _agentDraftUpdatedAt(Agent agent) {
    if (!getIt.isRegistered<ComposerDraftService>()) return null;
    final service = getIt<ComposerDraftService>();
    final fromAgent =
        service.draftUpdatedAt(ComposerDraftService.agentListKey(agent.id));
    if (fromAgent != null) return fromAgent;
    final channelId = _list.agentChannelId(agent.id);
    if (channelId == null) return null;
    return service.draftUpdatedAt(channelId);
  }

  String _groupDraftText(Channel group) {
    if (!getIt.isRegistered<ComposerDraftService>()) return '';
    final service = getIt<ComposerDraftService>();
    final byFamily =
        service.getDraft(ComposerDraftService.groupListKey(group.groupFamilyId));
    if (byFamily.isNotEmpty) return byFamily;
    final byId = service.getDraft(ComposerDraftService.groupListKey(group.id));
    if (byId.isNotEmpty) return byId;
    final channelId =
        _list.groupChannelId(group.id) ?? _list.groupChannelId(group.groupFamilyId);
    if (channelId == null) return '';
    return service.getDraft(channelId);
  }

  DateTime? _groupDraftUpdatedAt(Channel group) {
    if (!getIt.isRegistered<ComposerDraftService>()) return null;
    final service = getIt<ComposerDraftService>();
    final byFamily = service.draftUpdatedAt(
      ComposerDraftService.groupListKey(group.groupFamilyId),
    );
    if (byFamily != null) return byFamily;
    final byId =
        service.draftUpdatedAt(ComposerDraftService.groupListKey(group.id));
    if (byId != null) return byId;
    final channelId =
        _list.groupChannelId(group.id) ?? _list.groupChannelId(group.groupFamilyId);
    if (channelId == null) return null;
    return service.draftUpdatedAt(channelId);
  }

  /// WeChat-style subtitle: typing > pending approval > draft > last message / empty.
  Widget _buildConversationSubtitle({
    required bool isTyping,
    required String typingText,
    required String draft,
    required String lastContent,
    required String emptyText,
    bool pendingApproval = false,
  }) {
    final l10n = AppLocalizations.of(context);
    if (isTyping) {
      return Text(
        typingText,
        style: TextStyle(
          fontSize: 13,
          color: Colors.green[600],
          fontStyle: FontStyle.italic,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (pendingApproval) {
      return Text(
        l10n.approval_waitingReview,
        style: TextStyle(
          fontSize: 13,
          color: Colors.orange[800],
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (draft.trimRight().isNotEmpty) {
      final preview = draft.replaceAll(RegExp(r'\s+'), ' ').trim();
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: l10n.home_draftPrefix,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.red,
              ),
            ),
            TextSpan(
              text: preview,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      lastContent.isNotEmpty ? lastContent : emptyText,
      style: TextStyle(
        fontSize: 13,
        color: Colors.grey[500],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 主页标题：中文「惜宝」，英文「ShePaw」，居中显示（微信风格）。
  String _homeAppBarTitle(BuildContext context) {
    return AppLocalizations.of(context).appTitle;
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    final isSearching = widget.embedded && _searchController.text.trim().isNotEmpty;

    // Full-area open via DrawerSwipeDetector: clearly rightward swipes open the
    // drawer from the middle; vertical-dominant moves yield to list scrolling.
    // Scaffold's built-in edge drag stays off so it cannot steal diagonal scrolls.
    return DrawerSwipeDetector(
      enabled: !widget.embedded,
      onOpenDrawer: widget.embedded
          ? null
          : () => _scaffoldKey.currentState?.openDrawer(),
      verticalScrollSlop: 18,
      blockLeadingEdgeDrawerGesture: !widget.embedded,
      child: Scaffold(
        key: _scaffoldKey,
        appBar: widget.embedded
            ? _buildEmbeddedAppBar(iconColor)
            : AppBar(
                title: Text(
                  _homeAppBarTitle(context),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                centerTitle: true,
                elevation: 0,
                scrolledUnderElevation: 0.5,
                leading: IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                actions: [_buildAppBarTrailingActions(iconColor)],
              ),
        // 左侧抽屉菜单 (hidden in embedded mode)
        drawer: widget.embedded ? null : _buildDrawer(),
        drawerEnableOpenDragGesture: false,
        body: isSearching ? _buildEmbeddedSearchBody() : _buildBody(),
      ),
    );
  }

  /// 桌面版会话列表标题栏：搜索输入框 + 添加按钮（微信/QQ 桌面风格）。
  PreferredSizeWidget _buildEmbeddedAppBar(Color iconColor) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      title: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: l10n.common_search,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 32,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => _searchController.clear(),
                          )
                        : null,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                        color: colorScheme.primary.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildCompactAppBarIconButton(
              key: _addButtonKey,
              icon: SvgPicture.asset(
                'assets/icons/add_circle.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
              ),
              tooltip: l10n.home_addAgent,
              onPressed: _showAddMenu,
            ),
          ],
        ),
      ),
    );
  }

  static const double _appBarActionEdgeGap = 12;

  Widget _buildAppBarTrailingActions(Color iconColor) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: _appBarActionEdgeGap),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCompactAppBarIconButton(
            icon: const Icon(Icons.search),
            tooltip: l10n.common_search,
            onPressed: _openSearch,
          ),
          const SizedBox(width: _appBarActionEdgeGap),
          _buildCompactAppBarIconButton(
            key: _addButtonKey,
            icon: SvgPicture.asset(
              'assets/icons/add_circle.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
            ),
            tooltip: l10n.home_addAgent,
            onPressed: _showAddMenu,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactAppBarIconButton({
    Key? key,
    required Widget icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    // 布局宽度贴合 24px 图标，避免 IconButton 默认最小宽度把两图标间距撑大。
    return IconButton(
      key: key,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 40),
      style: IconButton.styleFrom(
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  void _openSearch() {
    final databaseService = _databaseService;
    final messageSearchService = MessageSearchService(databaseService);
    showShepawSearch(
      context: context,
      delegate: AgentSearchDelegate(
        agents: _agents,
        databaseService: databaseService,
        messageSearchService: messageSearchService,
        onResultSelected: (selection) {
          _handleSearchSelection(selection);
        },
      ),
    );
  }

  /// 构建左侧抽屉菜单
  Widget _buildDrawer() {
    final l10n = AppLocalizations.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // App 品牌头部
            Container(
              width: double.infinity,
              color: Theme.of(context).primaryColor,
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/images/shepaw_icon.png',
                      width: 64,
                      height: 64,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'ShePaw',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            
            // 菜单列表
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.contacts_outlined),
                    title: Text(l10n.drawer_contacts),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ContactsScreen(),
                        ),
                      ).then((_) => _loadAgents(silent: true));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text(l10n.storage_title),
                    subtitle: Text(l10n.storage_subtitle),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const StorageSpaceScreen(),
                        ),
                      );
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: Text(l10n.drawer_settings),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            
            // 版本信息
            Padding(
              padding: const EdgeInsets.all(16),
              child: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.version ?? '';
                  return Text(
                    'ShePaw v$version',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }


  /// 桌面版：在会话列表区域展示搜索结果。
  Widget _buildEmbeddedSearchBody() {
    final l10n = AppLocalizations.of(context);
    final query = _searchController.text.trim();
    final agentResults = _filteredAgents;
    final hasAgents = agentResults.isNotEmpty;
    final hasChannels = _searchChannelResults.isNotEmpty;
    final hasMessages = _searchMessageResults.isNotEmpty;
    final hasPeerMessages = _searchPeerMessageResults.isNotEmpty;

    if (_isEmbeddedSearching &&
        !hasAgents &&
        !hasChannels &&
        !hasMessages &&
        !hasPeerMessages) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!hasAgents && !hasChannels && !hasMessages && !hasPeerMessages) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              l10n.home_searchNoResults,
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        if (hasAgents) ...[
          _buildEmbeddedSearchSectionHeader(
            l10n.home_searchSectionAgents,
            agentResults.length,
          ),
          ...agentResults.map(_buildEmbeddedSearchAgentTile),
        ],
        if (hasChannels) ...[
          _buildEmbeddedSearchSectionHeader(
            l10n.home_searchSectionGroups,
            _searchChannelResults.length,
          ),
          ..._searchChannelResults.map(_buildEmbeddedSearchChannelTile),
        ],
        if (hasMessages) ...[
          _buildEmbeddedSearchSectionHeader(
            l10n.home_searchSectionMessages,
            _searchMessageResults.length,
          ),
          ..._searchMessageResults.map(
            (r) => _buildEmbeddedSearchMessageTile(r, query),
          ),
        ],
        if (hasPeerMessages) ...[
          _buildEmbeddedSearchSectionHeader(
            l10n.home_searchSectionPeerMessages,
            _searchPeerMessageResults.length,
          ),
          ..._searchPeerMessageResults.map(
            (r) => _buildEmbeddedSearchPeerMessageTile(r, query),
          ),
        ],
      ],
    );
  }

  Widget _buildEmbeddedSearchSectionHeader(String title, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmbeddedSearchAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final displayName = SheService.isSheIdentity(agent.id, agent.metadata)
        ? SheService.resolveDisplayName(agent.name, l10n.she_name)
        : agent.name;
    return ListTile(
      dense: true,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: AvatarImage(
          avatar: agent.avatar,
          size: 40,
          borderRadius: 10,
          fallback: Text(
            agent.name.isNotEmpty ? agent.name[0] : 'A',
            style: const TextStyle(fontSize: 20),
          ),
        ),
      ),
      title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        agent.description ?? agent.type ?? 'AI Agent',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _handleSearchSelection(SearchSelection(agent: agent)),
    );
  }

  Widget _buildEmbeddedSearchChannelTile(Channel channel) {
    return ListTile(
      dense: true,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(
          channel.isGroup ? Icons.group : Icons.chat_bubble_outline,
          color: AppColors.primaryDark,
          size: 20,
        ),
      ),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        channel.description ?? (channel.isGroup ? 'Group' : 'Chat'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _handleSearchSelection(SearchSelection(channel: channel)),
    );
  }

  Widget _buildEmbeddedSearchMessageTile(MessageSearchResult result, String query) {
    final message = result.message;
    final isMyMessage = message.from.type == 'user';
    return InkWell(
      onTap: () => _handleSearchSelection(SearchSelection(
        messageChannelId: message.channelId,
        highlightMessageId: message.id,
      )),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  flex: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      result.channelName.isNotEmpty ? result.channelName : '?',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    message.senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: isMyMessage
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _formatMessageSearchTime(message.timestampMs),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _buildEmbeddedHighlightedContent(message.content, query),
          ],
        ),
      ),
    );
  }

  Widget _buildEmbeddedSearchPeerMessageTile(
    PeerMessageSearchResult result,
    String query,
  ) {
    final message = result.message;
    return InkWell(
      onTap: () => _handleSearchSelection(SearchSelection(
        peerId: message.peerId,
        highlightMessageId: message.id,
      )),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      result.peerName.isNotEmpty ? result.peerName : '?',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatMessageSearchTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _buildEmbeddedHighlightedContent(message.content, query),
          ],
        ),
      ),
    );
  }

  Widget _buildEmbeddedHighlightedContent(String content, String query) {
    final baseStyle = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 13,
    );
    if (query.isEmpty) {
      return Text(
        content,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    final flat = content.replaceAll(RegExp(r'\s+'), ' ');
    final lowerFlat = flat.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerFlat.indexOf(lowerQuery);
    if (matchIndex == -1) {
      return Text(
        flat,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    const windowSize = 40;
    final snippetStart = matchIndex > windowSize ? matchIndex - windowSize : 0;
    final matchEnd = matchIndex + query.length;
    final snippetEnd = (matchEnd + windowSize).clamp(0, flat.length);
    final before = flat.substring(snippetStart, matchIndex);
    final match = flat.substring(matchIndex, matchEnd);
    final after = flat.substring(matchEnd, snippetEnd);

    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          if (snippetStart > 0) const TextSpan(text: '...'),
          TextSpan(text: before),
          TextSpan(
            text: match,
            style: TextStyle(
              backgroundColor: Colors.yellow[200],
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: after),
          if (snippetEnd < flat.length) const TextSpan(text: '...'),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _formatMessageSearchTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      final l10n = AppLocalizations.of(context);
    final weekDays = [
        l10n.home_weekMon,
        l10n.home_weekTue,
        l10n.home_weekWed,
        l10n.home_weekThu,
        l10n.home_weekFri,
        l10n.home_weekSat,
        l10n.home_weekSun,
      ];
      return weekDays[dt.weekday - 1];
    }
    return '${dt.month}/${dt.day}';
  }

  /// 构建主页body内容
  Widget _buildBody() {
    final l10n = AppLocalizations.of(context);
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_agents.isEmpty && _groupChannels.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.home_noAgents,
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.home_noAgentsHint,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }

    final totalItems = _sortedConversations.length;

    return RefreshIndicator(
      onRefresh: () => _loadAgents(silent: true),
      child: ListView.builder(
        itemCount: totalItems,
        itemBuilder: (context, index) {
          final item = _sortedConversations[index];
          if (item.isGroup) {
            return KeyedSubtree(
              key: ValueKey('group_${item.group!.id}'),
              child: _buildGroupTile(item.group!),
            );
          }
          if (item.isPeer) {
            return KeyedSubtree(
              key: ValueKey('peer_${item.peer!.id}'),
              child: _buildPeerTile(item.peer!),
            );
          }
          return KeyedSubtree(
            key: ValueKey('agent_${item.agent!.id}'),
            child: _buildAgentTile(item.agent!),
          );
        },
      ),
    );
  }

  /// 标题栏添加按钮：从按钮下方弹出菜单。
  Future<void> _showAddMenu() async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlay.size;
    const menuWidth = 180.0;
    const gap = 6.0;

    RelativeRect position;
    final buttonBox = _addButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (buttonBox != null) {
      final bottomRight = buttonBox.localToGlobal(
        buttonBox.size.bottomRight(Offset.zero),
        ancestor: overlay,
      );
      position = RelativeRect.fromLTRB(
        bottomRight.dx - menuWidth,
        bottomRight.dy + gap,
        overlaySize.width - bottomRight.dx,
        overlaySize.height - bottomRight.dy - gap,
      );
    } else {
      position = RelativeRect.fromLTRB(
        overlaySize.width - menuWidth - _appBarActionEdgeGap,
        kToolbarHeight + MediaQuery.of(context).padding.top + gap,
        _appBarActionEdgeGap,
        0,
      );
    }

    final colorScheme = Theme.of(context).colorScheme;

    final action = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints.tightFor(width: menuWidth),
      color: colorScheme.surface,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.6)),
      ),
      items: [
        _buildAddMenuItem(
          value: 'agent',
          icon: Icons.person_add_outlined,
          label: l10n.home_addAgent,
        ),
        _buildAddMenuItem(
          value: 'group',
          icon: Icons.group_add,
          label: l10n.home_createGroup,
        ),
        _buildAddMenuItem(
          value: 'device',
          icon: Icons.devices_outlined,
          label: l10n.home_addDevice,
        ),
        if (!widget.embedded)
          _buildAddMenuItem(
            value: 'scan',
            icon: Icons.qr_code_scanner,
            label: l10n.home_scanConnect,
          ),
      ],
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'agent':
        if (widget.embedded && widget.onAddAgent != null) {
          widget.onAddAgent!();
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const AddRemoteAgentScreen(),
            ),
          );
          if (mounted) _loadAgents(silent: true);
        }
      case 'group':
        if (widget.embedded && widget.onCreateGroup != null) {
          widget.onCreateGroup!();
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const CreateGroupScreen(),
            ),
          );
          if (mounted) _loadAgents(silent: true);
        }
      case 'device':
        if (widget.embedded && widget.onPairDevice != null) {
          widget.onPairDevice!();
        } else {
          await PeerPairingScreen.show(context);
          if (mounted) _loadAgents(silent: true);
        }
      case 'scan':
        await PeerPairingScreen.show(
          context,
          initialTabIndex: PeerPairingScreen.scanTabIndex,
        );
        if (mounted) _loadAgents(silent: true);
    }
  }

  PopupMenuItem<String> _buildAddMenuItem({
    required String value,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildGroupTile(Channel group) {
    final l10n = AppLocalizations.of(context);
    final latestMsg = _groupLatestMessages[group.id];
    final unreadCount = _groupUnreadCounts[group.id] ?? 0;
    final lastContent = latestMsg?['content'] as String? ?? '';
    final lastTime = latestMsg?['created_at'] as String?;
    final draft = _groupDraftText(group);
    final draftUpdatedAt = _groupDraftUpdatedAt(group);
    final memberCount = group.memberIds.where((id) => id != 'user').length;
    final sessionIds = _groupSessionChannelIds[group.id] ?? {};
    final isGroupTyping = sessionIds.intersection(_typingChannelIds).isNotEmpty;
    final pendingApproval = _list.groupHasPendingApproval(group);

    final isSelected = widget.embedded &&
        widget.selectedConversation != null &&
        widget.selectedConversation!.groupFamilyId != null &&
        widget.selectedConversation!.groupFamilyId == group.groupFamilyId;

    final timeLabel = draft.trimRight().isNotEmpty && draftUpdatedAt != null
        ? _formatDateTime(draftUpdatedAt)
        : (lastTime != null ? _formatTime(lastTime) : '');

    return InkWell(
      onTap: () async {
        if (widget.embedded && widget.onConversationSelected != null) {
          // Embedded mode: find active session and fire callback
          final latestChannelId = await _databaseService.getLatestActiveGroupChannel(group.groupFamilyId);
          final targetChannelId = latestChannelId ?? group.id;
          _list.clearGroupUnread(group.id);
          widget.onConversationSelected!(ConversationSelection(
            channelId: targetChannelId,
            groupFamilyId: group.groupFamilyId,
          ));
          return;
        }

        // Find the most recently active session for this group family
        final latestChannelId = await _databaseService.getLatestActiveGroupChannel(group.groupFamilyId);
        final targetChannelId = latestChannelId ?? group.id;

        await _databaseService.touchChannelUpdatedAt(targetChannelId);
        await _databaseService.markChannelMessagesAsRead(targetChannelId);
        _list.clearGroupUnread(group.id);

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(channelId: targetChannelId),
          ),
        ).then((_) async {
          // Reload full list in case the group was deleted or modified
          _publishComposerDrafts();
          await _loadAgents(silent: true);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? AppColors.primary.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            // Group avatar
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.group, size: 20, color: AppColors.primary),
                ),
                if (unreadCount > 0)
                  AvatarUnreadBadgeOverlay(count: unreadCount)
                else if (pendingApproval)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.orange[700],
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
            // Group name + last message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeLabel.isNotEmpty)
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: _buildConversationSubtitle(
                          isTyping: isGroupTyping,
                          typingText: l10n.home_typing,
                          draft: draft,
                          lastContent: lastContent,
                          emptyText: l10n.home_noMessages,
                          pendingApproval: pendingApproval,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.home_agentsCount(memberCount),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Handle a selection from the global search delegate using the same
  /// navigation flow as tapping items in the conversation list.
  Future<void> _handleSearchSelection(SearchSelection selection) async {
    if (selection.agent != null) {
      // Agent result — reuse the same logic as _buildAgentTile onTap
      final agent = selection.agent!;

      if (widget.embedded && widget.onConversationSelected != null) {
        const userId = 'user';
        final activeChannelId =
            await _chatService.getLatestActiveChannelId(userId, agent.id);
        final channelId =
            activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
        await _databaseService.touchChannelUpdatedAt(channelId);
        _list.clearAgentUnread(agent.id);
        widget.onConversationSelected!(ConversationSelection(
          agentId: agent.id,
          agentName: agent.name,
          agentAvatar: agent.avatar,
          channelId: channelId,
        ));
        return;
      }

      const userId = 'user';
      final activeChannelId =
          await _chatService.getLatestActiveChannelId(userId, agent.id);
      final channelId =
          activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
      await _databaseService.touchChannelUpdatedAt(channelId);
      await _databaseService.markChannelMessagesAsRead(channelId);
      _list.clearAgentUnread(agent.id);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
            channelId: channelId,
          ),
        ),
      ).then((_) async {
        const userId = 'user';
        final activeChannelId =
            await _chatService.getLatestActiveChannelId(userId, agent.id);
        final channelId =
            activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
        await _databaseService.markChannelMessagesAsRead(channelId);
        _publishComposerDrafts();
        _loadAgents(silent: true);
      });
    } else if (selection.channel != null) {
      // Channel/group result — reuse the same logic as _buildGroupTile onTap
      final channel = selection.channel!;

      if (widget.embedded && widget.onConversationSelected != null) {
        setState(() {
          _groupUnreadCounts[channel.id] = 0;
        });
        widget.onConversationSelected!(ConversationSelection(
          channelId: channel.id,
          groupFamilyId: channel.isGroup ? channel.groupFamilyId : null,
        ));
        return;
      }

      final latestChannelId = channel.isGroup
          ? await _databaseService
              .getLatestActiveGroupChannel(channel.groupFamilyId)
          : null;
      final targetChannelId = latestChannelId ?? channel.id;

      await _databaseService.touchChannelUpdatedAt(targetChannelId);
      await _databaseService.markChannelMessagesAsRead(targetChannelId);
      setState(() {
        _groupUnreadCounts[channel.id] = 0;
      });

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(channelId: targetChannelId),
        ),
      ).then((_) async {
        await _loadAgents(silent: true);
      });
    } else if (selection.messageChannelId != null) {
      // Message result — navigate to the channel with highlight
      final channelId = selection.messageChannelId!;

      if (widget.embedded && widget.onConversationSelected != null) {
        widget.onConversationSelected!(ConversationSelection(
          channelId: channelId,
          highlightMessageId: selection.highlightMessageId,
        ));
        return;
      }

      await _databaseService.markChannelMessagesAsRead(channelId);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            channelId: channelId,
            highlightMessageId: selection.highlightMessageId,
          ),
        ),
      ).then((_) async {
        await _loadAgents(silent: true);
      });
    } else if (selection.peerId != null) {
      final peerId = selection.peerId!;
      final peer = _pairedPeers.where((p) => p.id == peerId).firstOrNull;

      if (widget.embedded && widget.onConversationSelected != null) {
        _list.clearPeerUnread(peerId);
        widget.onConversationSelected!(ConversationSelection(
          peerId: peerId,
          highlightMessageId: selection.highlightMessageId,
        ));
        return;
      }

      if (peer == null) return;

      _list.clearPeerUnread(peerId);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PeerChatScreen(
            peer: peer,
            highlightMessageId: selection.highlightMessageId,
          ),
        ),
      ).then((_) async {
        await _loadAgents(silent: true);
      });
    }
  }

  Widget _buildAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final displayName = SheService.isSheIdentity(agent.id, agent.metadata)
        ? SheService.resolveDisplayName(agent.name, l10n.she_name)
        : agent.name;
    final latestMsg = _latestMessages[agent.id];
    final unreadCount = _unreadCounts[agent.id] ?? 0;
    final lastContent = latestMsg?['content'] as String? ?? '';
    final lastTime = latestMsg?['created_at'] as String?;
    final draft = _agentDraftText(agent);
    final draftUpdatedAt = _agentDraftUpdatedAt(agent);
    final pendingApproval = _list.agentHasPendingApproval(agent.id);

    final isSelected = widget.embedded &&
        widget.selectedConversation != null &&
        widget.selectedConversation!.agentId == agent.id;

    final timeLabel = draft.trimRight().isNotEmpty && draftUpdatedAt != null
        ? _formatDateTime(draftUpdatedAt)
        : (lastTime != null ? _formatTime(lastTime) : '');

    return InkWell(
      onTap: () async {
        if (widget.embedded && widget.onConversationSelected != null) {
          const userId = 'user';
          final activeChannelId =
              await _chatService.getLatestActiveChannelId(userId, agent.id);
          final channelId =
              activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
          await _databaseService.touchChannelUpdatedAt(channelId);
          _list.clearAgentUnread(agent.id);
          widget.onConversationSelected!(ConversationSelection(
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
            channelId: channelId,
          ));
          return;
        }

        // 进入聊天前标记该 channel 所有消息为已读
        const userId = 'user';
        final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agent.id);
        final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
        await _databaseService.touchChannelUpdatedAt(channelId);
        await _databaseService.markChannelMessagesAsRead(channelId);
        // 立即清除本地未读缓存
        _list.clearAgentUnread(agent.id);

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              agentId: agent.id,
              agentName: agent.name,
              agentAvatar: agent.avatar,
              channelId: channelId,
            ),
          ),
        ).then((_) async {
          // 从聊天返回后先标记已读，再刷新最新消息和未读数
          const userId = 'user';
          final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agent.id);
          final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
          await _databaseService.markChannelMessagesAsRead(channelId);
          // Reload agents to pick up avatar/name changes made in detail screen
          _publishComposerDrafts();
          _loadAgents(silent: true);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? AppColors.primary.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            // Agent头像 + 未读红点 / 待审角标
            _buildAgentAvatar(agent, unreadCount, pendingApproval: pendingApproval),
            const SizedBox(width: 12),
            // 中间：名称 + 最近消息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 名称行
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (agent.isPeerAgent) ...[
                              const SizedBox(width: 6),
                              _buildPeerSourceBadge(agent.sourcePeerName),
                            ],
                          ],
                        ),
                      ),
                      // 最近消息时间 / 草稿时间
                      if (timeLabel.isNotEmpty)
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 最近消息内容 / typing状态 / 草稿 + 右侧状态
                  Row(
                    children: [
                      Expanded(
                        child: _buildConversationSubtitle(
                          isTyping: _typingAgentIds.contains(agent.id),
                          typingText: l10n.home_typing,
                          draft: draft,
                          lastContent: lastContent,
                          emptyText: l10n.home_noMessages,
                          pendingApproval: pendingApproval,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 在线/离线/思考中 状态
                      _buildStatusLabel(agent),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 连接角色小徽标：标记本机是发起方还是被连接方。
  Widget _buildPeerRoleBadge(PairedPeer peer) {
    final l10n = AppLocalizations.of(context);
    final isInitiator = peer.pairingRole == PeerPairingRole.initiator;
    final color = PeerDeviceStyle.forPeer(peer).labelColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isInitiator ? Icons.call_made : Icons.call_received,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            peer.pairingRoleShortLabel(l10n) ?? '',
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }

  /// 来源标识小徽标：标记该 agent 来自某台配对设备。
  Widget _buildPeerSourceBadge(String? sourceName) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 11, color: colorScheme.primary),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              sourceName ?? AppLocalizations.of(context).peerPairing_title,
              style: TextStyle(fontSize: 10, color: colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerTile(PairedPeer peer) {
    final l10n = AppLocalizations.of(context);
    final isConnected = PeerConnectionManager.instance.getPeerState(peer.id) ==
        PeerConnectionState.connected;
    final lastContent = _peerLatestContent[peer.id] ?? '';
    final lastTimestamp = _peerLatestTime[peer.id];
    final lastTime = lastTimestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(lastTimestamp).toIso8601String()
        : null;
    final unreadCount = _peerUnreadCounts[peer.id] ?? 0;

    final isSelected = widget.embedded &&
        widget.selectedConversation != null &&
        widget.selectedConversation!.peerId == peer.id;

    return InkWell(
      onTap: () {
        if (widget.embedded && widget.onConversationSelected != null) {
          _list.clearPeerUnread(peer.id);
          widget.onConversationSelected!(ConversationSelection(peerId: peer.id));
          return;
        }
        _list.clearPeerUnread(peer.id);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PeerChatScreen(peer: peer),
          ),
        ).then((_) => _loadAgents(silent: true));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? AppColors.primary.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            // 设备头像 + 未读红点
            Stack(
              clipBehavior: Clip.none,
              children: [
                PeerDeviceIcon(peer: peer, size: 40, borderRadius: 10),
                // 在线状态
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: isConnected ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                // 未读数
                if (unreadCount > 0)
                  AvatarUnreadBadgeOverlay(count: unreadCount),
              ],
            ),
            const SizedBox(width: 12),
            // 名称 + 最新消息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                peer.deviceName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (peer.pairingRole != null) ...[
                              const SizedBox(width: 6),
                              _buildPeerRoleBadge(peer),
                            ],
                          ],
                        ),
                      ),
                      if (lastTime != null)
                        Text(
                          _formatTime(lastTime),
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.lock, size: 12, color: Colors.green[400]),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          lastContent.isNotEmpty
                              ? lastContent
                              : (isConnected
                                  ? l10n.peerSettings_online
                                  : l10n.peerSettings_offline),
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[500],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
