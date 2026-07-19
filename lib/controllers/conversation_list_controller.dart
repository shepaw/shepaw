import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import '../services/chat_service.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
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

  static const _prefKeyCollapsedPeers = 'home_collapsed_peer_ids';

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
  Set<String> _collapsedPeerIds = {};

  ConversationSelection? _activeSelection;
  bool _disposed = false;
  bool _healthCheckRunning = false;
  Timer? _healthCheckTimer;

  StreamSubscription? _peerMessageSub;
  StreamSubscription? _peerEventSub;
  StreamSubscription? _peerListChangedSub;
  StreamSubscription? _agentsChangedSub;

  List<Agent> get agents => _agents;
  List<Agent> get filteredAgents => _filteredAgents;
  List<Channel> get groupChannels => _groupChannels;
  List<PairedPeer> get pairedPeers => _pairedPeers;
  List<ConversationListItem> get entries => _entries;
  bool get isLoading => _isLoading;
  Set<String> get typingAgentIds => _typingAgentIds;
  Set<String> get typingChannelIds => _typingChannelIds;
  Set<String> get collapsedPeerIds => _collapsedPeerIds;

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

  void attach() {
    _chatService.typingAgentIds.addListener(_onTypingChanged);
    _chatService.typingChannelIds.addListener(_onTypingChanged);

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
        refresh(silent: true);
      }
    });

    _peerListChangedSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) {
      if (_disposed) return;
      refresh(silent: true);
    });

    _agentsChangedSub =
        getIt<RemoteAgentService>().agentsChanged.listen((_) {
      if (_disposed) return;
      refresh(silent: true);
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

  Future<void> loadCollapsedPeerIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefKeyCollapsedPeers) ?? [];
    if (_disposed) return;
    _collapsedPeerIds = ids.toSet();
    _rebuildEntries();
    notifyListeners();
  }

  Future<void> _saveCollapsedPeerIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefKeyCollapsedPeers,
      _collapsedPeerIds.toList(),
    );
  }

  int peerAgentCount(String peerId) {
    return _agents
        .where((a) => a.isPeerAgent && a.sourcePeerId == peerId)
        .length;
  }

  void togglePeerCollapsed(String peerId) {
    if (_collapsedPeerIds.contains(peerId)) {
      _collapsedPeerIds.remove(peerId);
    } else {
      _collapsedPeerIds.add(peerId);
    }
    _rebuildEntries();
    notifyListeners();
    _saveCollapsedPeerIds();
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

    try {
      final agents = await _apiService.getAgents();
      await _loadAgentPreviews(agents);

      final allChannels = await _databaseService.getAllChannels();
      final groups =
          allChannels.where((c) => c.isGroup && c.parentGroupId == null).toList();
      await _loadGroupPreviews(groups);

      List<PairedPeer> peers = [];
      try {
        peers = await PeerConnectionManager.instance.getAllPeers();
        final liveIds = peers.map((p) => p.id).toSet();
        _peerLatestContent.removeWhere((id, _) => !liveIds.contains(id));
        _peerLatestTime.removeWhere((id, _) => !liveIds.contains(id));
        _peerUnreadCounts.removeWhere((id, _) => !liveIds.contains(id));
        final collapsedBefore = _collapsedPeerIds.length;
        _collapsedPeerIds.removeWhere((id) => !liveIds.contains(id));
        if (_collapsedPeerIds.length != collapsedBefore) {
          await _saveCollapsedPeerIds();
        }
        await _loadPeerPreviews(peers);
      } catch (_) {}

      if (_disposed) return;
      _agents = agents;
      _filteredAgents = _applySearchFilter(agents);
      _groupChannels = groups;
      _pairedPeers = peers;
      _rebuildEntries();
      _isLoading = false;
      notifyListeners();
      LoggerService().info(
        'Loaded ${agents.length} agents, ${groups.length} groups',
        tag: 'ConversationList',
      );
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
    const userId = 'user';
    for (final agentId in agentIds) {
      final activeChannelId =
          await _chatService.getLatestActiveChannelId(userId, agentId);
      final channelId =
          activeChannelId ?? _chatService.generateChannelId(userId, agentId);
      final latestMsg =
          await _databaseService.getLatestChannelMessage(channelId);
      final unreadCount =
          await _databaseService.getUnreadCountByChannel(channelId);
      _latestMessages[agentId] = latestMsg;
      // 用户正在该频道里查看（如 She 频道收到 [Agent Reply] 注入）→
      // 角标按 0 计：消息已在其眼前，且聊天页的 reconcile 会标记已读，
      // 此处兜底消除"标记已读"与"角标重算"的先后竞态。
      _unreadCounts[agentId] =
          AppLifecycleService().activeChannelId == channelId ? 0 : unreadCount;
    }
    if (_disposed) return;
    _rebuildEntries();
    notifyListeners();
  }

  Future<void> _refreshGroupPreviews(Set<String> channelIds) async {
    for (final group in _groupChannels) {
      final sessionIds = _groupSessionChannelIds[group.id] ?? {};
      if (channelIds.intersection(sessionIds).isEmpty) continue;

      final sessions =
          await _databaseService.getGroupSessions(group.groupFamilyId);
      int totalUnread = 0;
      final activeChannelId = await _databaseService
          .getLatestActiveGroupChannel(group.groupFamilyId);
      Map<String, dynamic>? activeMsg;

      for (final session in sessions) {
        var unread =
            await _databaseService.getUnreadCountByChannel(session.id);
        // 用户正在查看的群会话不计未读（消息已在其眼前）
        if (session.id == AppLifecycleService().activeChannelId) unread = 0;
        totalUnread += unread;
        if (session.id == activeChannelId) {
          activeMsg =
              await _databaseService.getLatestChannelMessage(session.id);
        }
      }

      _groupLatestMessages[group.id] = activeMsg;
      _groupUnreadCounts[group.id] = totalUnread;
    }
    if (_disposed) return;
    _rebuildEntries();
    notifyListeners();
  }

  Future<void> _loadAgentPreviews(List<Agent> agents) async {
    const userId = 'user';
    for (final agent in agents) {
      final activeChannelId =
          await _chatService.getLatestActiveChannelId(userId, agent.id);
      final channelId =
          activeChannelId ?? _chatService.generateChannelId(userId, agent.id);
      final latestMsg =
          await _databaseService.getLatestChannelMessage(channelId);
      final unreadCount =
          await _databaseService.getUnreadCountByChannel(channelId);
      _latestMessages[agent.id] = latestMsg;
      _unreadCounts[agent.id] =
          AppLifecycleService().activeChannelId == channelId ? 0 : unreadCount;
    }
  }

  Future<void> _loadGroupPreviews(List<Channel> groups) async {
    for (final group in groups) {
      final sessions =
          await _databaseService.getGroupSessions(group.groupFamilyId);
      int totalUnread = 0;

      _groupSessionChannelIds[group.id] = {
        group.id,
        ...sessions.map((s) => s.id),
      };

      final activeChannelId = await _databaseService
          .getLatestActiveGroupChannel(group.groupFamilyId);
      Map<String, dynamic>? activeMsg;

      for (final session in sessions) {
        var unread =
            await _databaseService.getUnreadCountByChannel(session.id);
        // 用户正在查看的群会话不计未读（消息已在其眼前）
        if (session.id == AppLifecycleService().activeChannelId) unread = 0;
        totalUnread += unread;
        if (session.id == activeChannelId) {
          activeMsg =
              await _databaseService.getLatestChannelMessage(session.id);
        }
      }

      _groupLatestMessages[group.id] = activeMsg;
      _groupUnreadCounts[group.id] = totalUnread;
    }
  }

  Future<void> _loadPeerPreviews(List<PairedPeer> peers) async {
    final storage = PeerStorageService();
    final myDeviceId = await PeerPairingService.instance.getDeviceId();
    for (final peer in peers) {
      final messages = await storage.getMessages(peer.id, limit: 1);
      if (messages.isNotEmpty) {
        _peerLatestContent[peer.id] = messages.first.content;
        _peerLatestTime[peer.id] = messages.first.timestamp;
      }
      final recent = await storage.getMessages(peer.id, limit: 100);
      final unread = recent
          .where((m) =>
              m.senderId != myDeviceId &&
              m.delivery != PeerMessageDelivery.read)
          .length;
      _peerUnreadCounts[peer.id] = unread;
    }
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
        final freshAgents = await _apiService.getAgents();
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

  List<Agent> _applySearchFilter(List<Agent> agents) {
    final query = _searchQuery.toLowerCase();
    if (query.isEmpty) return agents;
    return agents.where((agent) {
      return agent.name.toLowerCase().contains(query) ||
          (agent.type?.toLowerCase().contains(query) ?? false) ||
          (agent.description?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  void _rebuildEntries() {
    _entries = buildSortedConversations(
      filteredAgents: _filteredAgents,
      groupChannels: _groupChannels,
      pairedPeers: _pairedPeers,
      searchQuery: _searchQuery,
      latestMessages: _latestMessages,
      groupLatestMessages: _groupLatestMessages,
      peerLatestTime: _peerLatestTime,
      collapsedPeerIds: _collapsedPeerIds,
    );
  }

  /// Pure builder used by [refresh] and unit tests.
  static List<ConversationListItem> buildSortedConversations({
    required List<Agent> filteredAgents,
    required List<Channel> groupChannels,
    required List<PairedPeer> pairedPeers,
    required String searchQuery,
    required Map<String, Map<String, dynamic>?> latestMessages,
    required Map<String, Map<String, dynamic>?> groupLatestMessages,
    required Map<String, int> peerLatestTime,
    required Set<String> collapsedPeerIds,
  }) {
    final query = searchQuery.toLowerCase();
    final pairedPeerIds = pairedPeers.map((p) => p.id).toSet();
    final blocks = <ConversationListBlock>[];

    DateTime? agentLastMessageTime(Agent agent) {
      final timeStr = latestMessages[agent.id]?['created_at'] as String?;
      return timeStr != null ? DateTime.tryParse(timeStr) : null;
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

    DateTime? latestOf(Iterable<DateTime?> times) {
      DateTime? latest;
      for (final time in times) {
        if (time == null) continue;
        if (latest == null || time.isAfter(latest)) latest = time;
      }
      return latest;
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
      if (agent.isPeerAgent &&
          agent.sourcePeerId != null &&
          pairedPeerIds.contains(agent.sourcePeerId)) {
        continue;
      }
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
      final time = timeStr != null ? DateTime.tryParse(timeStr) : null;
      blocks.add(
        ConversationListBlock.standalone(ConversationListItem.group(group, time)),
      );
    }

    for (final peer in pairedPeers) {
      final peerNameMatches =
          query.isEmpty || peer.deviceName.toLowerCase().contains(query);

      final childAgents = <Agent>[];
      for (final agent in filteredAgents) {
        if (!agent.isPeerAgent || agent.sourcePeerId != peer.id) continue;
        childAgents.add(agent);
      }

      if (query.isNotEmpty && !peerNameMatches && childAgents.isEmpty) {
        continue;
      }

      final peerTime = peerLastMessageTime(peer);
      final peerItem = ConversationListItem.peer(peer, peerTime);

      final visibleAgentItems = <ConversationListItem>[];
      final allAgentTimes = <DateTime?>[];
      for (final agent in childAgents) {
        final time = agentLastMessageTime(agent);
        allAgentTimes.add(time);
        final isCollapsed =
            query.isEmpty && collapsedPeerIds.contains(peer.id);
        if (!isCollapsed) {
          visibleAgentItems.add(ConversationListItem.agent(agent, time));
        }
      }

      visibleAgentItems.sort((a, b) {
        if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
        if (a.lastMessageTime == null) return 1;
        if (b.lastMessageTime == null) return -1;
        return b.lastMessageTime!.compareTo(a.lastMessageTime!);
      });

      blocks.add(ConversationListBlock.peerGroup(
        peerItem: peerItem,
        agentItems: visibleAgentItems,
        sortTime: latestOf([peerTime, ...allAgentTimes]),
      ));
    }

    blocks.sort(compareBlocks);
    return blocks.expand((block) => block.items).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _chatService.typingAgentIds.removeListener(_onTypingChanged);
    _chatService.typingChannelIds.removeListener(_onTypingChanged);
    _healthCheckTimer?.cancel();
    _peerMessageSub?.cancel();
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    _agentsChangedSub?.cancel();
    super.dispose();
  }
}
