import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/remote_agent_service.dart';
import '../services/token_service.dart';
import '../services/chat_service.dart';
import '../services/logger_service.dart';
import 'remote_agent_list_screen.dart';
import 'channel_list_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'model_management_screen.dart';
import 'skill_management_screen.dart';
import 'cli_config_management_screen.dart';
import '../task/screens/scheduled_tasks_management_screen.dart';
import '../services/model_registry.dart';
import '../widgets/agent_search_delegate.dart';
import '../services/message_search_service.dart';
import '../l10n/app_localizations.dart';
import '../providers/notification_provider.dart';
import '../main.dart' show setGlobalNotificationProvider;
import '../models/conversation_selection.dart';
import 'package:provider/provider.dart';
import '../utils/layout_utils.dart';

/// Tagged union for a unified conversation list item (agent or group).
class _ConversationItem {
  final Agent? agent;
  final Channel? group;
  final DateTime? lastMessageTime;

  _ConversationItem.agent(this.agent, this.lastMessageTime) : group = null;
  _ConversationItem.group(this.group, this.lastMessageTime) : agent = null;

  bool get isAgent => agent != null;
  bool get isGroup => group != null;
}

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

  const HomeScreen({
    Key? key,
    this.embedded = false,
    this.selectedConversation,
    this.onConversationSelected,
  }) : super(key: key);

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  final ChatService _chatService = ChatService();
  List<Agent> _agents = [];
  List<Agent> _filteredAgents = [];
  List<Channel> _groupChannels = [];
  List<_ConversationItem> _sortedConversations = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  // Typing agent IDs from ChatService (1:1 chats only)
  Set<String> _typingAgentIds = {};
  // Typing channel IDs from ChatService (1:1 + group chats)
  Set<String> _typingChannelIds = {};

  // 每个 agent 的最新消息缓存
  final Map<String, Map<String, dynamic>?> _latestMessages = {};
  // 每个 agent 的未读消息数缓存
  final Map<String, int> _unreadCounts = {};
  // Group channel preview data (keyed by channelId)
  final Map<String, Map<String, dynamic>?> _groupLatestMessages = {};
  final Map<String, int> _groupUnreadCounts = {};
  // Cache: groupId -> set of session channelIds (for typing indicator lookup)
  final Map<String, Set<String>> _groupSessionChannelIds = {};

  // FAB 动画控制
  late AnimationController _buttonAnimatedIcon;

  // 定期健康检查定时器
  Timer? _healthCheckTimer;

  /// Public accessor so DesktopHomeScreen can trigger a refresh via GlobalKey.
  void reloadAgents() => _loadAgents();

  /// Public accessor for the current agents list (used by desktop sidebar search).
  List<Agent> get agents => _agents;

  @override
  void initState() {
    super.initState();
    _loadAgents();
    _searchController.addListener(_onSearchChanged);

    // Listen for typing status changes
    ChatService().typingAgentIds.addListener(_onTypingChanged);
    ChatService().typingChannelIds.addListener(_onTypingChanged);

    // 初始化动画控制器
    _buttonAnimatedIcon = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // 启动定期健康检查（每30秒）
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshAgentStatus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifProvider = context.read<NotificationProvider>();
    _chatService.setNotificationProvider(notifProvider);
    setGlobalNotificationProvider(notifProvider);
  }

  @override
  void dispose() {
    ChatService().typingAgentIds.removeListener(_onTypingChanged);
    ChatService().typingChannelIds.removeListener(_onTypingChanged);
    _healthCheckTimer?.cancel();
    _searchController.dispose();
    _buttonAnimatedIcon.dispose();
    super.dispose();
  }

  // 上一次的 typing agent IDs，用于检测 agent 完成输出
  Set<String> _prevTypingAgentIds = {};
  // 上一次的 typing channel IDs，用于检测群聊 agent 完成输出
  Set<String> _prevTypingChannelIds = {};

  void _onTypingChanged() {
    if (mounted) {
      final newTypingIds = ChatService().typingAgentIds.value;
      final newTypingChannelIds = ChatService().typingChannelIds.value;
      // 找出刚从 typing 变为非 typing 的 agent（即刚完成输出的 agent）
      final finishedAgentIds = _prevTypingAgentIds.difference(newTypingIds);
      _prevTypingAgentIds = Set.from(newTypingIds);
      // 找出刚完成 typing 的 channel（用于刷新群聊预览）
      final finishedChannelIds = _prevTypingChannelIds.difference(newTypingChannelIds);
      _prevTypingChannelIds = Set.from(newTypingChannelIds);

      setState(() {
        _typingAgentIds = newTypingIds;
        _typingChannelIds = newTypingChannelIds;
      });

      // 对刚完成输出的 agent 刷新其最新消息和未读数
      if (finishedAgentIds.isNotEmpty) {
        _refreshAgentPreviews(finishedAgentIds);
      }
      // 对刚完成输出的群聊 channel 刷新预览
      if (finishedChannelIds.isNotEmpty) {
        _refreshGroupPreviews(finishedChannelIds);
      }
    }
  }

  /// 刷新指定 agent 的最新消息和未读数
  Future<void> _refreshAgentPreviews(Set<String> agentIds) async {
    const userId = 'user';
    for (final agentId in agentIds) {
      final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agentId);
      final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agentId);
      final latestMsg = await _databaseService.getLatestChannelMessage(channelId);
      final unreadCount = await _databaseService.getUnreadCountByChannel(channelId);
      _latestMessages[agentId] = latestMsg;
      _unreadCounts[agentId] = unreadCount;
    }
    if (mounted) {
      setState(() {
        _sortedConversations = _buildSortedConversations();
      });
    }
  }

  /// 刷新指定 channel 完成 typing 后的群聊预览
  Future<void> _refreshGroupPreviews(Set<String> channelIds) async {
    for (final group in _groupChannels) {
      // Check if any of the finished channelIds belong to this group
      final sessionIds = _groupSessionChannelIds[group.id] ?? {};
      if (channelIds.intersection(sessionIds).isEmpty) continue;

      final sessions = await _databaseService.getGroupSessions(group.groupFamilyId);
      int totalUnread = 0;
      final activeChannelId = await _databaseService.getLatestActiveGroupChannel(group.groupFamilyId);
      Map<String, dynamic>? activeMsg;

      for (final session in sessions) {
        final unread = await _databaseService.getUnreadCountByChannel(session.id);
        totalUnread += unread;
        if (session.id == activeChannelId) {
          activeMsg = await _databaseService.getLatestChannelMessage(session.id);
        }
      }

      _groupLatestMessages[group.id] = activeMsg;
      _groupUnreadCounts[group.id] = totalUnread;
    }
    if (mounted) {
      setState(() {
        _sortedConversations = _buildSortedConversations();
      });
    }
  }

  /// Agent头像（右下角显示未读红点）
  Widget _buildAgentAvatar(Agent agent, int unreadCount) {
    return Stack(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: agent.avatar.length <= 2
              ? Text(
                  agent.avatar,
                  style: const TextStyle(fontSize: 24),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: agent.avatar.startsWith('/') && !agent.avatar.startsWith('http')
                      ? Image.file(
                          File(agent.avatar),
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Text(
                              agent.name.isNotEmpty ? agent.name[0] : 'A',
                              style: const TextStyle(fontSize: 24),
                            );
                          },
                        )
                      : Image.network(
                          agent.avatar,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Text(
                              agent.name.isNotEmpty ? agent.name[0] : 'A',
                              style: const TextStyle(fontSize: 24),
                            );
                          },
                        ),
                ),
        ),
        // 未读消息红点
        if (unreadCount > 0)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              padding: unreadCount > 9
                  ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
                  : const EdgeInsets.all(0),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                unreadCount > 99 ? '99+' : '$unreadCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
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

  /// 加载每个 agent 的最新消息和未读数
  Future<void> _loadAgentPreviews(List<Agent> agents) async {
    const userId = 'user';
    for (final agent in agents) {
      // Use the active session (same as what ChatScreen enters), not the default channel
      final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agent.id);
      final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
      final latestMsg = await _databaseService.getLatestChannelMessage(channelId);
      final unreadCount = await _databaseService.getUnreadCountByChannel(channelId);
      _latestMessages[agent.id] = latestMsg;
      _unreadCounts[agent.id] = unreadCount;
    }
  }

  /// 加载每个 group channel 的最新消息和未读数（across all sessions in the family）
  Future<void> _loadGroupPreviews(List<Channel> groups) async {
    for (final group in groups) {
      // Get all sessions in this group family
      final sessions = await _databaseService.getGroupSessions(group.groupFamilyId);
      int totalUnread = 0;

      // Cache session channelIds for typing indicator lookup
      _groupSessionChannelIds[group.id] = {
        group.id,
        ...sessions.map((s) => s.id),
      };

      // Find the active session (most recently updated) — this is the one the user will enter
      final activeChannelId = await _databaseService.getLatestActiveGroupChannel(group.groupFamilyId);
      Map<String, dynamic>? activeMsg;

      for (final session in sessions) {
        final unread = await _databaseService.getUnreadCountByChannel(session.id);
        totalUnread += unread;

        // Only show the preview from the active session
        if (session.id == activeChannelId) {
          activeMsg = await _databaseService.getLatestChannelMessage(session.id);
        }
      }

      _groupLatestMessages[group.id] = activeMsg;
      _groupUnreadCounts[group.id] = totalUnread;
    }
  }

  /// 后台执行健康检查，完成后静默更新在线状态（不显示 loading）
  void _runHealthCheckInBackground() {
    () async {
      try {
        final tokenService = TokenService(_databaseService);
        final remoteAgentService = RemoteAgentService(_databaseService, tokenService);
        await remoteAgentService.checkAllAgentsHealth(timeout: const Duration(seconds: 3));

        if (!mounted) return;
        final freshAgents = await _apiService.getAgents();
        if (!mounted) return;
        setState(() {
          _agents = freshAgents;
          _filteredAgents = _applySearchFilter(freshAgents);
          _sortedConversations = _buildSortedConversations();
        });
      } catch (e) {
        LoggerService().error('Background health check failed', tag: 'Home', error: e);
      }
    }();
  }

  /// 加载Agent列表
  Future<void> _loadAgents() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // 直接从数据库加载最新的 Agent 列表（毫秒级，立即展示）
      final agents = await _apiService.getAgents();
      // 加载每个 agent 的最新消息和未读数
      await _loadAgentPreviews(agents);

      // Load group channels (only show parent groups, not child sessions)
      final allChannels = await _databaseService.getAllChannels();
      final groups = allChannels.where((c) => c.isGroup && c.parentGroupId == null).toList();
      await _loadGroupPreviews(groups);

      if (mounted) {
        setState(() {
          _agents = agents;
          _filteredAgents = _applySearchFilter(agents);
          _groupChannels = groups;
          _sortedConversations = _buildSortedConversations();
          _isLoading = false;
        });
      }
      LoggerService().info('Loaded ${agents.length} agents, ${groups.length} groups', tag: 'Home');
      _runHealthCheckInBackground(); // 后台异步健康检查，不阻塞列表展示
    } catch (e) {
      LoggerService().error('Failed to load agents', tag: 'Home', error: e);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 静默刷新 Agent 状态（不显示 loading 状态）
  Future<void> _refreshAgentStatus() async {
    try {
      final agents = await _apiService.getAgents();
      await _loadAgentPreviews(agents);

      final allChannels = await _databaseService.getAllChannels();
      final groups = allChannels.where((c) => c.isGroup && c.parentGroupId == null).toList();
      await _loadGroupPreviews(groups);

      if (mounted) {
        setState(() {
          _agents = agents;
          _filteredAgents = _applySearchFilter(agents);
          _groupChannels = groups;
          _sortedConversations = _buildSortedConversations();
        });
      }
      _runHealthCheckInBackground(); // 后台健康检查
    } catch (e) {
      LoggerService().error('Failed to refresh agent status', tag: 'Home', error: e);
    }
  }

  /// 根据当前搜索关键字过滤 Agent 列表
  List<Agent> _applySearchFilter(List<Agent> agents) {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) return agents;
    return agents.where((agent) {
      return agent.name.toLowerCase().contains(query) ||
             (agent.type?.toLowerCase().contains(query) ?? false) ||
             (agent.description?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  /// 搜索过滤
  void _onSearchChanged() {
    setState(() {
      _filteredAgents = _applySearchFilter(_agents);
      _sortedConversations = _buildSortedConversations();
    });
  }

  /// Build a merged, time-sorted list of agents and groups.
  List<_ConversationItem> _buildSortedConversations() {
    final query = _searchController.text.toLowerCase();
    final items = <_ConversationItem>[];

    for (final agent in _filteredAgents) {
      final msg = _latestMessages[agent.id];
      final timeStr = msg?['created_at'] as String?;
      final time = timeStr != null ? DateTime.tryParse(timeStr) : null;
      items.add(_ConversationItem.agent(agent, time));
    }

    for (final group in _groupChannels) {
      // Apply search filter to groups too
      if (query.isNotEmpty) {
        final matchesName = group.name.toLowerCase().contains(query);
        final matchesDesc = group.description?.toLowerCase().contains(query) ?? false;
        if (!matchesName && !matchesDesc) continue;
      }
      final msg = _groupLatestMessages[group.id];
      final timeStr = msg?['created_at'] as String?;
      final time = timeStr != null ? DateTime.tryParse(timeStr) : null;
      items.add(_ConversationItem.group(group, time));
    }

    // Sort by last message time descending; items with no messages go last.
    // She (is_she == true) always stays at the top.
    items.sort((a, b) {
      // She（pinned）永远排第一
      final aIsShe = a.agent?.metadata?['is_she'] == true;
      final bIsShe = b.agent?.metadata?['is_she'] == true;
      if (aIsShe && !bIsShe) return -1;
      if (!aIsShe && bIsShe) return 1;

      // 其余按最新消息时间排序
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });

    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ShePaw'),
        elevation: 1,
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        actions: [
          // 搜索按钮（展开搜索）— 桌面嵌入模式下搜索在侧边栏，不重复显示
          if (!widget.embedded)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                final databaseService = LocalDatabaseService();
                final messageSearchService = MessageSearchService(databaseService);
                showSearch(
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
              },
            ),
        ],
      ),
      // 左侧抽屉菜单 (hidden in embedded mode)
      drawer: widget.embedded ? null : _buildDrawer(),
      body: _buildBody(),
      floatingActionButton: widget.embedded ? null : _buildFloatingActionButton(),
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
                  const SizedBox(height: 4),
                  const Text(
                    'support@metamessager.com',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
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
                    leading: const Icon(Icons.person_add_outlined),
                    title: Text(l10n.drawer_newAgent),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AddRemoteAgentScreen(),
                        ),
                      ).then((_) => _loadAgents());
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.group_add_outlined),
                    title: Text(l10n.drawer_newGroup),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CreateGroupScreen(),
                        ),
                      ).then((_) => _loadAgents());
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.hub),
                    title: Text(l10n.toolModel_managementTitle),
                    subtitle: Text(
                      l10n.toolModel_count(ModelRegistry.instance.definitions.length),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ModelManagementScreen(),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(l10n.skillMgmt_title),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SkillManagementScreen(),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.terminal),
                    title: Text(l10n.osTool_configTitle),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CliConfigManagementScreen(),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
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
                      ).then((_) => _loadAgents());
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(l10n.scheduledTasks_title),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ScheduledTasksManagementScreen(),
                        ),
                      );
                    },
                  ),
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
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: Text(
                      l10n.drawer_logout,
                      style: const TextStyle(color: Colors.red),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showLogoutDialog();
                    },
                  ),
                ],
              ),
            ),
            
            // 版本信息
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.appVersion,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示退出登录确认对话框
  void _showLogoutDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.logout_confirmTitle),
        content: Text(l10n.logout_confirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/login',
                (route) => false,
              );
            },
            child: Text(
              l10n.common_confirm,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
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
      onRefresh: _loadAgents,
      child: ListView.builder(
        itemCount: totalItems,
        itemBuilder: (context, index) {
          final item = _sortedConversations[index];
          if (item.isGroup) {
            return _buildGroupTile(item.group!);
          }
          return _buildAgentTile(item.agent!);
        },
      ),
    );
  }

  /// 构建浮动操作按钮
  Widget _buildFloatingActionButton() {
    final l10n = AppLocalizations.of(context);
    return FloatingActionButton(
      onPressed: () {
        LayoutUtils.showAdaptivePanel(
          context: context,
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: Text(l10n.home_addAgent),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const AddRemoteAgentScreen(),
                    ),
                  ).then((_) => _loadAgents());
                },
              ),
              ListTile(
                leading: const Icon(Icons.group_add),
                title: Text(l10n.home_createGroup),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const CreateGroupScreen(),
                    ),
                  ).then((_) => _loadAgents());
                },
              ),
            ],
          ),
        );
      },
      child: const Icon(Icons.add),
    );
  }
  Widget _buildGroupTile(Channel group) {
    final l10n = AppLocalizations.of(context);
    final latestMsg = _groupLatestMessages[group.id];
    final unreadCount = _groupUnreadCounts[group.id] ?? 0;
    final lastContent = latestMsg?['content'] as String? ?? '';
    final lastTime = latestMsg?['created_at'] as String?;
    final memberCount = group.memberIds.where((id) => id != 'user').length;
    final sessionIds = _groupSessionChannelIds[group.id] ?? {};
    final isGroupTyping = sessionIds.intersection(_typingChannelIds).isNotEmpty;

    final isSelected = widget.embedded &&
        widget.selectedConversation != null &&
        widget.selectedConversation!.groupFamilyId != null &&
        widget.selectedConversation!.groupFamilyId == group.groupFamilyId;

    return InkWell(
      onTap: () async {
        if (widget.embedded && widget.onConversationSelected != null) {
          // Embedded mode: find active session and fire callback
          final latestChannelId = await _databaseService.getLatestActiveGroupChannel(group.groupFamilyId);
          final targetChannelId = latestChannelId ?? group.id;
          setState(() {
            _groupUnreadCounts[group.id] = 0;
          });
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
        setState(() {
          _groupUnreadCounts[group.id] = 0;
        });

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(channelId: targetChannelId),
          ),
        ).then((_) async {
          // Reload full list in case the group was deleted or modified
          await _loadAgents();
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? Colors.blue.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            // Group avatar
            Stack(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.blue[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.group, size: 28, color: Colors.blue),
                ),
                if (unreadCount > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: unreadCount > 9
                          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
                          : const EdgeInsets.all(0),
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
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
                      if (lastTime != null)
                        Text(
                          _formatTime(lastTime),
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
                        child: isGroupTyping
                            ? Text(
                                l10n.home_typing,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.green[600],
                                  fontStyle: FontStyle.italic,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : Text(
                                lastContent.isNotEmpty ? lastContent : l10n.home_noMessages,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
        setState(() {
          _unreadCounts[agent.id] = 0;
        });
        widget.onConversationSelected!(ConversationSelection(
          agentId: agent.id,
          agentName: agent.name,
          agentAvatar: agent.avatar,
        ));
        return;
      }

      const userId = 'user';
      final activeChannelId =
          await _chatService.getLatestActiveChannelId(userId, agent.id);
      final channelId =
          activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
      await _databaseService.markChannelMessagesAsRead(channelId);
      setState(() {
        _unreadCounts[agent.id] = 0;
      });

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
          ),
        ),
      ).then((_) async {
        const userId = 'user';
        final activeChannelId =
            await _chatService.getLatestActiveChannelId(userId, agent.id);
        final channelId =
            activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
        await _databaseService.markChannelMessagesAsRead(channelId);
        _loadAgents();
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
        await _loadAgents();
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
        await _loadAgents();
      });
    }
  }

  Widget _buildAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final latestMsg = _latestMessages[agent.id];
    final unreadCount = _unreadCounts[agent.id] ?? 0;
    final lastContent = latestMsg?['content'] as String? ?? '';
    final lastTime = latestMsg?['created_at'] as String?;

    final isSelected = widget.embedded &&
        widget.selectedConversation != null &&
        widget.selectedConversation!.agentId == agent.id;

    return InkWell(
      onTap: () async {
        if (widget.embedded && widget.onConversationSelected != null) {
          // Embedded mode: fire callback, don't push route
          setState(() {
            _unreadCounts[agent.id] = 0;
          });
          widget.onConversationSelected!(ConversationSelection(
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
          ));
          return;
        }

        // 进入聊天前标记该 channel 所有消息为已读
        const userId = 'user';
        final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agent.id);
        final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
        await _databaseService.markChannelMessagesAsRead(channelId);
        // 立即清除本地未读缓存
        setState(() {
          _unreadCounts[agent.id] = 0;
        });

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              agentId: agent.id,
              agentName: agent.name,
              agentAvatar: agent.avatar,
            ),
          ),
        ).then((_) async {
          // 从聊天返回后先标记已读，再刷新最新消息和未读数
          const userId = 'user';
          final activeChannelId = await _chatService.getLatestActiveChannelId(userId, agent.id);
          final channelId = activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
          await _databaseService.markChannelMessagesAsRead(channelId);
          // Reload agents to pick up avatar/name changes made in detail screen
          _loadAgents();
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? Colors.blue.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            // Agent头像 + 未读红点
            _buildAgentAvatar(agent, unreadCount),
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
                        child: Text(
                          agent.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 最近消息时间
                      if (lastTime != null)
                        Text(
                          _formatTime(lastTime),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 最近消息内容 / typing状态 + 右侧状态
                  Row(
                    children: [
                      Expanded(
                        child: _typingAgentIds.contains(agent.id)
                            ? Text(
                                l10n.home_typing,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.green[600],
                                  fontStyle: FontStyle.italic,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : Text(
                                lastContent.isNotEmpty ? lastContent : l10n.home_noMessages,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
}
