import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../widgets/model_icon.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/remote_agent_service.dart';
import '../service_locator.dart' show getIt;
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
import '../widgets/shepaw_search_page.dart';
import '../widgets/avatar_image.dart';
import '../services/message_search_service.dart';
import '../services/she_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../providers/notification_provider.dart';
import '../models/conversation_selection.dart';
import '../peer/models/paired_peer.dart';
import '../peer/models/peer_message.dart';
import '../peer/screens/peer_chat_screen.dart';
import '../peer/widgets/peer_device_icon.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import 'package:provider/provider.dart';

/// Tagged union for a unified conversation list item (agent or group).
class _ConversationItem {
  final Agent? agent;
  final Channel? group;
  final PairedPeer? peer;
  final DateTime? lastMessageTime;

  _ConversationItem.agent(this.agent, this.lastMessageTime) : group = null, peer = null;
  _ConversationItem.group(this.group, this.lastMessageTime) : agent = null, peer = null;
  _ConversationItem.peer(this.peer, this.lastMessageTime) : agent = null, group = null;

  bool get isAgent => agent != null;
  bool get isGroup => group != null;
  bool get isPeer => peer != null;
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
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  final ChatService _chatService = ChatService();
  List<Agent> _agents = [];
  List<Agent> _filteredAgents = [];
  List<Channel> _groupChannels = [];
  List<PairedPeer> _pairedPeers = [];
  List<_ConversationItem> _sortedConversations = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _addButtonKey = GlobalKey();
  late final MessageSearchService _messageSearchService;
  List<Channel> _searchChannelResults = [];
  List<MessageSearchResult> _searchMessageResults = [];
  bool _isEmbeddedSearching = false;
  Timer? _searchDebounce;

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
  // P2P peer preview data
  final Map<String, String> _peerLatestContent = {};
  final Map<String, int> _peerLatestTime = {};
  final Map<String, int> _peerUnreadCounts = {};

  // 定期健康检查定时器
  Timer? _healthCheckTimer;
  bool _healthCheckRunning = false;

  // P2P 消息监听
  StreamSubscription? _peerMessageSub;
  // P2P 事件监听（连接/断开/删除时刷新列表）
  StreamSubscription? _peerEventSub;
  // P2P 设备列表变化监听（新增配对/删除配对时刷新会话列表）
  StreamSubscription? _peerListChangedSub;

  /// Public accessor so DesktopHomeScreen can trigger a refresh via GlobalKey.
  void reloadAgents() => _loadAgents(silent: true);

  /// Public accessor for the current agents list (used by desktop sidebar search).
  List<Agent> get agents => _agents;

  @override
  void initState() {
    super.initState();
    _messageSearchService = MessageSearchService(_databaseService);
    _loadAgents();
    _searchController.addListener(_onSearchChanged);

    // Listen for typing status changes
    ChatService().typingAgentIds.addListener(_onTypingChanged);
    ChatService().typingChannelIds.addListener(_onTypingChanged);

    // 监听 P2P 新消息，实时更新会话列表
    _peerMessageSub = PeerConnectionManager.instance.messages.listen((msg) {
      if (mounted) {
        setState(() {
          _peerLatestContent[msg.peerId] = msg.content;
          _peerLatestTime[msg.peerId] = msg.timestamp;
          // 桌面端当前正在查看该 peer 的聊天时，不增加未读数
          final isCurrentlyViewing = widget.embedded &&
              widget.selectedConversation?.peerId == msg.peerId;
          if (!isCurrentlyViewing) {
            _peerUnreadCounts[msg.peerId] = (_peerUnreadCounts[msg.peerId] ?? 0) + 1;
          }
          _sortedConversations = _buildSortedConversations();
        });
      }
    });

    // 监听 P2P 断开事件刷新在线状态（连接/新增由 peerListChanged 统一处理，避免重复刷新）
    _peerEventSub = PeerConnectionManager.instance.events.listen((event) {
      if (mounted && event.type == PeerConnectionEventType.disconnected) {
        _loadAgents(silent: true);
      }
    });

    // 监听 P2P 设备列表变化（新增/删除配对/连接建立）——立即刷新会话列表
    _peerListChangedSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      if (mounted) _loadAgents(silent: true);
    });

    // 定期健康检查（每30秒）——仅更新在线状态，避免整表刷新导致列表闪烁
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _runHealthCheckInBackground();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifProvider = context.read<NotificationProvider>();
    _chatService.setNotificationProvider(notifProvider);
  }

  @override
  void dispose() {
    ChatService().typingAgentIds.removeListener(_onTypingChanged);
    ChatService().typingChannelIds.removeListener(_onTypingChanged);
    _healthCheckTimer?.cancel();
    _peerMessageSub?.cancel();
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
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
              : AvatarImage(
                  avatar: agent.avatar,
                  size: 56,
                  borderRadius: 12,
                  fallback: Text(
                    agent.name.isNotEmpty ? agent.name[0] : 'A',
                    style: const TextStyle(fontSize: 24),
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

  /// 加载 peer 的最新消息和未读数
  Future<void> _loadPeerPreviews(List<PairedPeer> peers) async {
    final storage = PeerStorageService();
    final myDeviceId = await PeerPairingService.instance.getDeviceId();
    for (final peer in peers) {
      final messages = await storage.getMessages(peer.id, limit: 1);
      if (messages.isNotEmpty) {
        _peerLatestContent[peer.id] = messages.first.content;
        _peerLatestTime[peer.id] = messages.first.timestamp;
      }
      // 未读数：非我发的 + 还没标记为 read 的
      final recent = await storage.getMessages(peer.id, limit: 100);
      final unread = recent.where((m) =>
          m.senderId != myDeviceId &&
          m.delivery != PeerMessageDelivery.read
      ).length;
      _peerUnreadCounts[peer.id] = unread;
    }
  }

  /// 后台执行健康检查，完成后仅在在线状态变化时更新 UI（不显示 loading）
  void _runHealthCheckInBackground() {
    if (_healthCheckRunning) return;
    _healthCheckRunning = true;
    () async {
      try {
        final remoteAgentService = getIt<RemoteAgentService>();
        await remoteAgentService.checkAllAgentsHealth(timeout: const Duration(seconds: 3));

        if (!mounted) return;
        final freshAgents = await _apiService.getAgents();
        if (!mounted) return;
        if (!_agentOnlineStatusChanged(freshAgents, _agents)) return;

        setState(() {
          _agents = freshAgents;
          _filteredAgents = _applySearchFilter(freshAgents);
          _sortedConversations = _buildSortedConversations();
        });
      } catch (e) {
        LoggerService().error('Background health check failed', tag: 'Home', error: e);
      } finally {
        _healthCheckRunning = false;
      }
    }();
  }

  /// 比较 agent 列表的在线状态是否有变化（忽略 lastHeartbeat 等不影响 UI 的字段）
  bool _agentOnlineStatusChanged(List<Agent> fresh, List<Agent> current) {
    if (fresh.length != current.length) return true;
    final statusById = {for (final a in current) a.id: a.status.state};
    for (final agent in fresh) {
      if (statusById[agent.id] != agent.status.state) return true;
    }
    return false;
  }

  /// 加载 Agent 列表。
  /// [silent] 为 true 时不显示全屏 loading（用于从聊天返回、P2P 事件等后台刷新）。
  Future<void> _loadAgents({bool silent = false}) async {
    final showLoading = !silent && _agents.isEmpty && _groupChannels.isEmpty && _pairedPeers.isEmpty;
    if (showLoading) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      // 直接从数据库加载最新的 Agent 列表（毫秒级，立即展示）
      final agents = await _apiService.getAgents();
      // 加载每个 agent 的最新消息和未读数
      await _loadAgentPreviews(agents);

      // Load group channels (only show parent groups, not child sessions)
      final allChannels = await _databaseService.getAllChannels();
      final groups = allChannels.where((c) => c.isGroup && c.parentGroupId == null).toList();
      await _loadGroupPreviews(groups);

      // Load paired peers (有最近活跃记录的)
      List<PairedPeer> peers = [];
      try {
        peers = await PeerConnectionManager.instance.getAllPeers();
        // 清理已删除 peer 的陈旧预览缓存，避免会话列表残留旧设备
        final liveIds = peers.map((p) => p.id).toSet();
        _peerLatestContent.removeWhere((id, _) => !liveIds.contains(id));
        _peerLatestTime.removeWhere((id, _) => !liveIds.contains(id));
        _peerUnreadCounts.removeWhere((id, _) => !liveIds.contains(id));
        await _loadPeerPreviews(peers);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _agents = agents;
          _filteredAgents = _applySearchFilter(agents);
          _groupChannels = groups;
          _pairedPeers = peers;
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
    if (widget.embedded) {
      setState(() {});
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _performEmbeddedSearch(_searchController.text.trim());
      });
      return;
    }
    setState(() {
      _filteredAgents = _applySearchFilter(_agents);
      _sortedConversations = _buildSortedConversations();
    });
  }

  Future<void> _performEmbeddedSearch(String query) async {
    if (!widget.embedded) return;
    if (query.isEmpty) {
      setState(() {
        _filteredAgents = _agents;
        _searchChannelResults = [];
        _searchMessageResults = [];
        _isEmbeddedSearching = false;
        _sortedConversations = _buildSortedConversations();
      });
      return;
    }

    setState(() => _isEmbeddedSearching = true);

    final lowerQuery = query.toLowerCase();
    final agentResults = _agents.where((a) {
      return a.name.toLowerCase().contains(lowerQuery) ||
          (a.type?.toLowerCase().contains(lowerQuery) ?? false) ||
          (a.description?.toLowerCase().contains(lowerQuery) ?? false);
    }).toList();

    List<Channel> channelResults = [];
    List<MessageSearchResult> messageResults = [];
    try {
      final allChannels = await _databaseService.getAllChannels();
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

    if (!mounted || _searchController.text.trim() != query) return;
    setState(() {
      _filteredAgents = agentResults;
      _searchChannelResults = channelResults;
      _searchMessageResults = messageResults;
      _isEmbeddedSearching = false;
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

    // 已配对设备（有最近消息的加入会话列表）
    for (final peer in _pairedPeers) {
      if (query.isNotEmpty) {
        if (!peer.deviceName.toLowerCase().contains(query)) continue;
      }
      final msgTime = _peerLatestTime[peer.id];
      final time = msgTime != null
          ? DateTime.fromMillisecondsSinceEpoch(msgTime)
          : (peer.lastSeen != null
              ? DateTime.fromMillisecondsSinceEpoch(peer.lastSeen!)
              : DateTime.fromMillisecondsSinceEpoch(peer.pairedAt));
      items.add(_ConversationItem.peer(peer, time));
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

  /// 主页标题：中文「惜宝」，英文「ShePaw」，居中显示（微信风格）。
  String _homeAppBarTitle(BuildContext context) {
    return AppLocalizations.of(context).appTitle;
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    final isSearching = widget.embedded && _searchController.text.trim().isNotEmpty;

    return Scaffold(
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
              leading: Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
              actions: [_buildAppBarTrailingActions(iconColor)],
            ),
      // 左侧抽屉菜单 (hidden in embedded mode)
      drawer: widget.embedded ? null : _buildDrawer(),
      body: isSearching ? _buildEmbeddedSearchBody() : _buildBody(),
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
    final databaseService = LocalDatabaseService();
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
                    leading: const ModelIcon(),
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
                      ).then((_) => _loadAgents(silent: true));
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

    if (_isEmbeddedSearching &&
        !hasAgents &&
        !hasChannels &&
        !hasMessages) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!hasAgents && !hasChannels && !hasMessages) {
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
        ? l10n.she_name
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
        alignment: Alignment.center,
        child: agent.avatar.length <= 2
            ? Text(agent.avatar, style: const TextStyle(fontSize: 20))
            : AvatarImage(
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
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.group, size: 28, color: AppColors.primary),
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
    }
  }

  Widget _buildAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final displayName = SheService.isSheIdentity(agent.id, agent.metadata)
        ? l10n.she_name
        : agent.name;
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
          _loadAgents(silent: true);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? AppColors.primary.withValues(alpha: 0.08) : null,
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
              sourceName ?? '配对设备',
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
          setState(() => _peerUnreadCounts[peer.id] = 0);
          widget.onConversationSelected!(ConversationSelection(peerId: peer.id));
          return;
        }
        setState(() => _peerUnreadCounts[peer.id] = 0);
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
                PeerDeviceIcon(peer: peer, size: 48, borderRadius: 12),
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
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
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
