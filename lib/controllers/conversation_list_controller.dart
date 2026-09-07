import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/agent.dart';
import '../models/channel.dart';
import '../models/conversation_list_entry.dart';
import '../models/conversation_selection.dart';
import '../peer/models/paired_peer.dart';
import '../peer/models/peer_message.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../service_locator.dart' show getIt;
import '../services/app_lifecycle_service.dart';
import '../services/approval/pending_approval_hub.dart';
import '../services/approval/pending_approval_item.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../config/product_features.dart';
import '../services/remote_agent_service.dart';

/// Owns home conversation-list data: load, preview caches, P2P subscriptions,
/// sorting, and unread. Screens only render and navigate.
class ConversationListController extends ChangeNotifier {
  ConversationListController({
    LocalApiService? apiService,
    LocalDatabaseService? databaseService,
    ChatService? chatService,
  })  : _apiService = apiService ?? LocalApiService(),
        _databaseService = databaseService ??
            (getIt.isRegistered<LocalDatabaseService>()
                ? getIt<LocalDatabaseService>()
                : LocalDatabaseService()),
        _chatService = chatService ??
            (getIt.isRegistered<ChatService>()
                ? getIt<ChatService>()
                : ChatService());

  final LocalApiService _apiService;
  final LocalDatabaseService _databaseService;
  final ChatService _chatService;

  List<Agent> _agents = [];
  List<Agent> _filteredAgents = [];
  List<Channel> _groupChannels = [];
  List<PairedPeer> _pairedPeers = [];
  List<ConversationListItem> _entries = [];
  bool _isLoading = true;
  String _searchQuery = '';

  Set<String> _typingAgentIds = {};
  Set<String> _typingChannelIds = {};
  Set<String> _prevTypingAgentIds = {};
  Set<String> _prevTypingChannelIds = {};

  final Map<String, Map<String, dynamic>?> _latestMessages = {};
  final Map<String, int> _unreadCounts = {};
  final Map<String, Map<String, dynamic>?> _groupLatestMessages = {};
  final Map<String, int> _groupUnreadCounts = {};
  final Map<String, Set<String>> _groupSessionChannelIds = {};
  final Map<String, String> _peerLatestContent = {};
  final Map<String, int> _peerLatestTime = {};
  final Map<String, int> _peerUnreadCounts = {};

  /// Active channel id per agent / group, used to resolve drafts keyed by channel.
  final Map<String, String> _agentChannelIds = {};
  final Map<String, String> _groupChannelIds = {};

  ConversationSelection? _activeSelection;
  bool _disposed = false;
  bool _healthCheckRunning = false;
  Timer? _healthCheckTimer;

  bool _refreshInFlight = false;
  Timer? _pendingRefreshTimer;

  /// 后台刷新的合并窗口：peer 断连 / 设备列表变化 / agent 变化常常连发。
  static const Duration _kSilentRefreshDebounce = Duration(milliseconds: 150);

  StreamSubscription? _peerMessageSub;
  StreamSubscription? _peerEventSub;
  StreamSubscription? _peerListChangedSub;
  StreamSubscription? _agentsChangedSub;
  StreamSubscription<List<PendingApprovalItem>>? _approvalHubSub;

  ComposerDraftService? _draftService;

  List<Agent> get agents => _agents;
  List<Agent> get filteredAgents => _filteredAgents;
  List<Channel> get groupChannels => _groupChannels;
  List<PairedPeer> get pairedPeers => _pairedPeers;
  List<ConversationListItem> get entries => _entries;
  bool get isLoading => _isLoading;
  Set<String> get typingAgentIds => _typingAgentIds;
  Set<String> get typingChannelIds => _typingChannelIds;

  Map<String, Map<String, dynamic>?> get latestMessages => _latestMessages;
  Map<String, int> get unreadCounts => _unreadCounts;
  Map<String, Map<String, dynamic>?> get groupLatestMessages =>
      _groupLatestMessages;
  Map<String, int> get groupUnreadCounts => _groupUnreadCounts;
  Map<String, Set<String>> get groupSessionChannelIds =>
      _groupSessionChannelIds;
  Map<String, String> get peerLatestContent => _peerLatestContent;
  Map<String, int> get peerLatestTime => _peerLatestTime;
  Map<String, int> get peerUnreadCounts => _peerUnreadCounts;

  /// Active DM channel for [agentId], if known from the last preview load.
  String? agentChannelId(String agentId) => _agentChannelIds[agentId];

  /// Active session channel for [groupId], if known from the last preview load.
  String? groupChannelId(String groupId) => _groupChannelIds[groupId];

  /// Whether [agentId]'s DM has a pending high-priority approval.
  bool agentHasPendingApproval(String agentId) {
    final channelId = _agentChannelIds[agentId];
    return PendingApprovalHub.instance.any(
      (i) =>
          (i.agentId.isNotEmpty && i.agentId == agentId) ||
          (channelId != null && i.channelId == channelId),
    );
  }

  /// Whether [group] (or any of its sessions) has a pending approval.
  bool groupHasPendingApproval(Channel group) {
    final ids = <String>{
      group.id,
      group.groupFamilyId,
      if (_groupChannelIds[group.id] != null) _groupChannelIds[group.id]!,
      if (_groupChannelIds[group.groupFamilyId] != null)
        _groupChannelIds[group.groupFamilyId]!,
      ...?_groupSessionChannelIds[group.id],
      ...?_groupSessionChannelIds[group.groupFamilyId],
    };
    return PendingApprovalHub.instance.any((i) => ids.contains(i.channelId));
  }

  void attach() {
    _chatService.typingAgentIds.addListener(_onTypingChanged);
    _chatService.typingChannelIds.addListener(_onTypingChanged);

    _ensureDraftListener();

    _approvalHubSub = PendingApprovalHub.instance.stream.listen((_) {
      if (_disposed) return;
      notifyListeners();
    });

    _peerMessageSub = PeerConnectionManager.instance.messages.listen((msg) {
      if (_disposed) return;
      _peerLatestContent[msg.peerId] = msg.content;
      _peerLatestTime[msg.peerId] = msg.timestamp;
      final isCurrentlyViewing = _activeSelection?.peerId == msg.peerId;
      if (!isCurrentlyViewing) {
        _peerUnreadCounts[msg.peerId] =
            (_peerUnreadCounts[msg.peerId] ?? 0) + 1;
      }
      _rebuildEntries();
      notifyListeners();
    });

    _peerEventSub = PeerConnectionManager.instance.events.listen((event) {
      if (_disposed) return;
      if (event.type == PeerConnectionEventType.disconnected) {
        _scheduleSilentRefresh();
      }
    });

    _peerListChangedSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) {
      if (_disposed) return;
      _scheduleSilentRefresh();
    });

    _agentsChangedSub =
        getIt<RemoteAgentService>().agentsChanged.listen((_) {
      if (_disposed) return;
      _scheduleSilentRefresh();
    });

    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _runHealthCheckInBackground();
    });
  }

  /// Desktop embed: suppress peer unread while that peer chat is open.
  void setActiveSelection(ConversationSelection? selection) {
    _activeSelection = selection;
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    _filteredAgents = _applySearchFilter(_agents);
    _rebuildEntries();
    notifyListeners();
  }

  void clearAgentUnread(String agentId) {
    _unreadCounts[agentId] = 0;
    notifyListeners();
  }

  void clearGroupUnread(String groupId) {
    _groupUnreadCounts[groupId] = 0;
    notifyListeners();
  }

  void clearPeerUnread(String peerId) {
    _peerUnreadCounts[peerId] = 0;
    notifyListeners();
  }

  /// 合并连发的后台刷新：三个数据源的事件往往同时到达，逐个刷新会把全量
  /// 加载跑好几遍。已在跑的一轮结束后再补一次，避免并发写同一批缓存。
  void _scheduleSilentRefresh() {
    if (_disposed) return;
    _pendingRefreshTimer?.cancel();
    _pendingRefreshTimer = Timer(_kSilentRefreshDebounce, () {
      _pendingRefreshTimer = null;
      if (_refreshInFlight) {
        _scheduleSilentRefresh();
        return;
      }
      refresh(silent: true);
    });
  }

  /// Load agents / groups / peers. [silent] skips full-screen loading.
  Future<void> refresh({bool silent = false}) async {
    final showLoading = !silent &&
        _agents.isEmpty &&
        _groupChannels.isEmpty &&
        _pairedPeers.isEmpty;
    if (showLoading) {
      _isLoading = true;
      notifyListeners();
    }

    _refreshInFlight = true;
    try {
      // 三路数据源互不依赖，并行拉取：串行会把各自的往返时间累加。
      final results = await Future.wait<List<Object>>([
        _loadAgents(),
        _loadGroups(),
        _loadPeers(),
      ]);
      final agents = results[0] as List<Agent>;
      final groups = results[1] as List<Channel>;
      final peers = results[2] as List<PairedPeer>;

      if (_disposed) return;
      _agents = agents;
      _filteredAgents = _applySearchFilter(agents);
      _groupChannels = groups;
      _pairedPeers = peers;
      _rebuildEntries();
      _isLoading = false;
      notifyListeners();
      if (!silent) {
        LoggerService().debug(
          'Loaded ${agents.length} agents, ${groups.length} groups',
          tag: 'ConversationList',
        );
      }
      _runHealthCheckInBackground();
    } catch (e) {
      LoggerService().error(
        'Failed to load agents',
        tag: 'ConversationList',
        error: e,
      );
      if (_disposed) return;
      _isLoading = false;
      notifyListeners();
    } finally {
      _refreshInFlight = false;
    }
  }

  void _onTypingChanged() {
    if (_disposed) return;
    final newTypingIds = _chatService.typingAgentIds.value;
    final newTypingChannelIds = _chatService.typingChannelIds.value;
    final finishedAgentIds = _prevTypingAgentIds.difference(newTypingIds);
    _prevTypingAgentIds = Set.from(newTypingIds);
    final finishedChannelIds =
        _prevTypingChannelIds.difference(newTypingChannelIds);
    _prevTypingChannelIds = Set.from(newTypingChannelIds);

    _typingAgentIds = newTypingIds;
    _typingChannelIds = newTypingChannelIds;
    notifyListeners();

    if (finishedAgentIds.isNotEmpty) {
      _refreshAgentPreviews(finishedAgentIds);
    }
    if (finishedChannelIds.isNotEmpty) {
      _refreshGroupPreviews(finishedChannelIds);
    }
  }

  Future<void> _refreshAgentPreviews(Set<String> agentIds) async {
    await Future.wait(agentIds.map(_loadAgentPreview));
    if (_disposed) return;
    _rebuildEntries();
    notifyListeners();
  }

  Future<void> _refreshGroupPreviews(Set<String> channelIds) async {
    final affected = _groupChannels.where((group) {
      final sessionIds = _groupSessionChannelIds[group.id] ?? const {};
      return channelIds.intersection(sessionIds).isNotEmpty;
    }).toList();
    if (affected.isEmpty) return;

    await _loadGroupPreviews(affected);
    if (_disposed) return;
    _rebuildEntries();
    notifyListeners();
  }

  Future<List<Agent>> _loadAgents() async {
    final agents = _visibleOnThisApp(await _apiService.getAgents());
    await _loadAgentPreviews(agents);
    return agents;
  }

  /// 只取顶层群聊：getAllChannels 会为每个会话串行查成员（1+2N 次往返，N 为
  /// 全部会话数），而会话列表只需要群本身。
  Future<List<Channel>> _loadGroups() async {
    final groups = await _databaseService.getTopLevelGroups();
    await _loadGroupPreviews(groups);
    return groups;
  }

  /// 已配对设备；P2P 不可用时静默降级为空列表。
  Future<List<PairedPeer>> _loadPeers() async {
    try {
      final peers = await PeerConnectionManager.instance.getAllPeers();
      final liveIds = peers.map((p) => p.id).toSet();
      _peerLatestContent.removeWhere((id, _) => !liveIds.contains(id));
      _peerLatestTime.removeWhere((id, _) => !liveIds.contains(id));
      _peerUnreadCounts.removeWhere((id, _) => !liveIds.contains(id));
      await _loadPeerPreviews(peers);
      return peers;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadAgentPreviews(List<Agent> agents) async {
    await Future.wait(agents.map((agent) => _loadAgentPreview(agent.id)));
  }

  /// 单个 agent 的 DM 预览：活跃频道 / 最新消息 / 未读数。
  ///
  /// 逐 agent 串行是 3N 次 sqflite 往返，并发后整体等待时间接近一次往返。
  Future<void> _loadAgentPreview(String agentId) async {
    const userId = 'user';
    final activeChannelId =
        await _chatService.getLatestActiveChannelId(userId, agentId);
    final channelId =
        activeChannelId ?? _chatService.generateChannelId(userId, agentId);
    final latestMsg =
        await _databaseService.getLatestMessageForAgent(agentId);
    var unreadCount =
        await _databaseService.getUnreadCountForAgent(agentId);
    _agentChannelIds[agentId] = channelId;
    _latestMessages[agentId] = latestMsg;
    // 用户正在该频道里查看 → 角标按 0 计。
    if (AppLifecycleService().activeChannelId == channelId) {
      unreadCount = 0;
    }
    _unreadCounts[agentId] = unreadCount;
  }

  Future<void> _loadGroupPreviews(List<Channel> groups) async {
    if (groups.isEmpty) return;

    // 会话列表只用到会话 id，成员不参与预览/未读计算，因此走只取 id 的批量
    // 查询：每个群 1 次，而非 getGroupSessions 的 1+2N 次。
    final sessionIdsByGroup = <String, List<String>>{};
    await Future.wait(groups.map((group) async {
      sessionIdsByGroup[group.id] =
          await _databaseService.getGroupSessionIds(group.groupFamilyId);
    }));

    final allSessionIds = <String>[
      for (final ids in sessionIdsByGroup.values) ...ids,
    ];
    final unreadByChannel =
        await _databaseService.getUnreadCountsByChannels(allSessionIds);

    await Future.wait(groups.map((group) async {
      final sessionIds = sessionIdsByGroup[group.id] ?? const [];
      _groupSessionChannelIds[group.id] = {...sessionIds};

      final activeChannelId = await _databaseService
          .getLatestActiveGroupChannel(group.groupFamilyId);

      var totalUnread = 0;
      for (final sessionId in sessionIds) {
        if (sessionId == AppLifecycleService().activeChannelId) continue;
        totalUnread += unreadByChannel[sessionId] ?? 0;
      }

      if (activeChannelId != null) {
        _groupChannelIds[group.id] = activeChannelId;
        _groupChannelIds[group.groupFamilyId] = activeChannelId;
      }
      _groupLatestMessages[group.id] = await _databaseService
          .getLatestMessageForGroupFamily(group.groupFamilyId);
      _groupUnreadCounts[group.id] = totalUnread;
    }));
  }

  Future<void> _loadPeerPreviews(List<PairedPeer> peers) async {
    final storage = PeerStorageService();
    final myDeviceId = await PeerPairingService.instance.getDeviceId();
    // 单次查询同时给出最新预览与未读数：getMessages 按 timestamp DESC 排序，
    // 首条即最新消息，无需再单独查一次 limit:1。
    await Future.wait(peers.map((peer) async {
      final recent = await storage.getMessages(peer.id, limit: 100);
      if (recent.isNotEmpty) {
        _peerLatestContent[peer.id] = recent.first.content;
        _peerLatestTime[peer.id] = recent.first.timestamp;
      }
      _peerUnreadCounts[peer.id] = recent
          .where((m) =>
              m.senderId != myDeviceId &&
              m.delivery != PeerMessageDelivery.read)
          .length;
    }));
  }

  void _runHealthCheckInBackground() {
    if (_healthCheckRunning || _disposed) return;
    _healthCheckRunning = true;
    () async {
      try {
        final remoteAgentService = getIt<RemoteAgentService>();
        await remoteAgentService.checkAllAgentsHealth(
          timeout: const Duration(seconds: 3),
        );
        if (_disposed) return;
        final freshAgents =
            _visibleOnThisApp(await _apiService.getAgents());
        if (_disposed) return;
        if (!_agentOnlineStatusChanged(freshAgents, _agents)) return;

        _agents = freshAgents;
        _filteredAgents = _applySearchFilter(freshAgents);
        _rebuildEntries();
        notifyListeners();
      } catch (e) {
        LoggerService().error(
          'Background health check failed',
          tag: 'ConversationList',
          error: e,
        );
      } finally {
        _healthCheckRunning = false;
      }
    }();
  }

  bool _agentOnlineStatusChanged(List<Agent> fresh, List<Agent> current) {
    if (fresh.length != current.length) return true;
    final statusById = {for (final a in current) a.id: a.status.state};
    for (final agent in fresh) {
      if (statusById[agent.id] != agent.status.state) return true;
    }
    return false;
  }

  /// Peer agents the user hid in device settings stay out of the home list.
  static List<Agent> visibleOnThisApp(List<Agent> agents) =>
      agents.where((a) => !a.hiddenOnThisApp).toList();

  List<Agent> _visibleOnThisApp(List<Agent> agents) => visibleOnThisApp(agents);

  List<Agent> _applySearchFilter(List<Agent> agents) {
    final query = _searchQuery.toLowerCase();
    if (query.isEmpty) return agents;
    return agents.where((agent) {
      return agent.name.toLowerCase().contains(query) ||
          (agent.type?.toLowerCase().contains(query) ?? false) ||
          (agent.description?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  void _ensureDraftListener() {
    if (!getIt.isRegistered<ComposerDraftService>()) return;
    final service = getIt<ComposerDraftService>();
    if (identical(_draftService, service)) return;
    _draftService?.removeListener(_onDraftsChanged);
    _draftService = service;
    _draftService!.addListener(_onDraftsChanged);
  }

  void _onDraftsChanged() {
    if (_disposed) return;
    _ensureDraftListener();
    _rebuildEntries();
    notifyListeners();
  }

  void _rebuildEntries() {
    _ensureDraftListener();
    _entries = buildSortedConversations(
      filteredAgents: _filteredAgents,
      groupChannels: _groupChannels,
      pairedPeers: _pairedPeers,
      searchQuery: _searchQuery,
      latestMessages: _latestMessages,
      groupLatestMessages: _groupLatestMessages,
      peerLatestTime: _peerLatestTime,
      draftUpdatedAtForAgent: _draftUpdatedAtForAgent,
      draftUpdatedAtForGroup: _draftUpdatedAtForGroup,
      deviceChatUiEnabled: ProductFeatures.deviceChatUiEnabled,
    );
  }

  DateTime? _draftUpdatedAtForAgent(String agentId) {
    return _draftUpdatedAt(
      listKey: ComposerDraftService.agentListKey(agentId),
      channelId: _agentChannelIds[agentId],
    );
  }

  DateTime? _draftUpdatedAtForGroup(String groupId) {
    return _draftUpdatedAt(
      listKey: ComposerDraftService.groupListKey(groupId),
      channelId: _groupChannelIds[groupId],
    );
  }

  DateTime? _draftUpdatedAt({required String listKey, String? channelId}) {
    final service = _draftService ??
        (getIt.isRegistered<ComposerDraftService>()
            ? getIt<ComposerDraftService>()
            : null);
    if (service == null) return null;
    final fromList = service.draftUpdatedAt(listKey);
    if (fromList != null) return fromList;
    if (channelId != null && channelId.isNotEmpty) {
      return service.draftUpdatedAt(channelId);
    }
    return null;
  }

  /// Pure builder used by [refresh] and unit tests.
  ///
  /// Agent / group / peer 各自成行，按最近激活时间降序；She 置顶。
  /// 设备与 peer Agent 不再聚合（聚合在通讯录中完成）。
  ///
  /// 排序时间取「跨会话最新消息 / 草稿编辑时间」二者最大：
  /// 仅打开会话但不发消息、不改草稿不会顶到列表前面。
  static List<ConversationListItem> buildSortedConversations({
    required List<Agent> filteredAgents,
    required List<Channel> groupChannels,
    required List<PairedPeer> pairedPeers,
    required String searchQuery,
    required Map<String, Map<String, dynamic>?> latestMessages,
    required Map<String, Map<String, dynamic>?> groupLatestMessages,
    required Map<String, int> peerLatestTime,
    DateTime? Function(String agentId)? draftUpdatedAtForAgent,
    DateTime? Function(String groupId)? draftUpdatedAtForGroup,
    bool deviceChatUiEnabled = ProductFeatures.deviceChatUiEnabled,
  }) {
    final query = searchQuery.toLowerCase();
    final blocks = <ConversationListBlock>[];

    DateTime? latestOf(Iterable<DateTime?> times) {
      DateTime? latest;
      for (final time in times) {
        if (time == null) continue;
        if (latest == null || time.isAfter(latest)) latest = time;
      }
      return latest;
    }

    DateTime? agentLastMessageTime(Agent agent) {
      final timeStr = latestMessages[agent.id]?['created_at'] as String?;
      final msgTime = timeStr != null ? DateTime.tryParse(timeStr)?.toLocal() : null;
      final draftTime = draftUpdatedAtForAgent?.call(agent.id)?.toLocal();
      return latestOf([msgTime, draftTime]);
    }

    DateTime? peerLastMessageTime(PairedPeer peer) {
      final msgTime = peerLatestTime[peer.id];
      if (msgTime != null) {
        return DateTime.fromMillisecondsSinceEpoch(msgTime);
      }
      if (peer.lastSeen != null) {
        return DateTime.fromMillisecondsSinceEpoch(peer.lastSeen!);
      }
      return DateTime.fromMillisecondsSinceEpoch(peer.pairedAt);
    }

    int compareBlocks(ConversationListBlock a, ConversationListBlock b) {
      if (a.isShe && !b.isShe) return -1;
      if (!a.isShe && b.isShe) return 1;
      if (a.sortTime == null && b.sortTime == null) return 0;
      if (a.sortTime == null) return 1;
      if (b.sortTime == null) return -1;
      return b.sortTime!.compareTo(a.sortTime!);
    }

    for (final agent in filteredAgents) {
      final time = agentLastMessageTime(agent);
      final item = ConversationListItem.agent(agent, time);
      blocks.add(ConversationListBlock.standalone(
        item,
        isShe: agent.metadata?['is_she'] == true,
      ));
    }

    for (final group in groupChannels) {
      if (query.isNotEmpty) {
        final matchesName = group.name.toLowerCase().contains(query);
        final matchesDesc =
            group.description?.toLowerCase().contains(query) ?? false;
        if (!matchesName && !matchesDesc) continue;
      }
      final timeStr = groupLatestMessages[group.id]?['created_at'] as String?;
      final msgTime = timeStr != null ? DateTime.tryParse(timeStr)?.toLocal() : null;
      final draftTime = (draftUpdatedAtForGroup?.call(group.groupFamilyId) ??
              draftUpdatedAtForGroup?.call(group.id))
          ?.toLocal();
      final time = latestOf([msgTime, draftTime]);
      blocks.add(
        ConversationListBlock.standalone(ConversationListItem.group(group, time)),
      );
    }

    if (deviceChatUiEnabled) {
      for (final peer in pairedPeers) {
        if (query.isNotEmpty &&
            !peer.deviceName.toLowerCase().contains(query)) {
          continue;
        }
        final peerTime = peerLastMessageTime(peer);
        blocks.add(
          ConversationListBlock.standalone(
            ConversationListItem.peer(peer, peerTime),
          ),
        );
      }
    }

    blocks.sort(compareBlocks);
    return blocks.expand((block) => block.items).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _draftService?.removeListener(_onDraftsChanged);
    _chatService.typingAgentIds.removeListener(_onTypingChanged);
    _chatService.typingChannelIds.removeListener(_onTypingChanged);
    _healthCheckTimer?.cancel();
    _pendingRefreshTimer?.cancel();
    _peerMessageSub?.cancel();
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    _agentsChangedSub?.cancel();
    _approvalHubSub?.cancel();
    super.dispose();
  }
}
