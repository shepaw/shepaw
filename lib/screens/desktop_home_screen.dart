import 'dart:async';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/conversation_selection.dart';
import '../models/remote_agent.dart';
import '../l10n/app_localizations.dart';
import '../config/product_features.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_chat_screen.dart';
import '../peer/screens/peer_manual_input_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'channel_trace_screen.dart';
import 'group_task_list_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'group_detail_screen.dart';
import 'remote_agent_detail_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'storage_space_manage_screen.dart';
import 'instruction_set_screen.dart';
import 'jade_slip_screen.dart';
import '../widgets/storage/storage_space_list_panel.dart';
import '../storage/store_protocol.dart';
import '../utils/layout_utils.dart';
import '../services/logger_service.dart';
import '../services/native_window_service.dart';
import '../services/chat_navigation_service.dart';
import '../services/local_database_service.dart';
import '../services/onboarding_service.dart';
import '../services/she_service.dart';
import '../services/update_service.dart';
import '../service_locator.dart' show getIt;
import '../widgets/update_settings_badge.dart';
import '../widgets/local_agent_hub_prompt.dart';

/// Desktop split-panel layout similar to WeChat desktop.
/// Left: icon sidebar + conversation / contacts / storage list.
/// Right: chat / contact detail / storage overview or entry / settings.
class DesktopHomeScreen extends StatefulWidget {
  const DesktopHomeScreen({Key? key}) : super(key: key);

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

/// Middle column content (WeChat-style).
enum _LeftPanelMode { conversations, contacts, storage }

/// Tracks what the right panel is currently displaying.
enum _RightPanelView {
  empty,
  chat,
  settings,
  addAgent,
  createGroup,
  pairDevice,
  pairDeviceInput,
  contactAgent,
  contactGroup,
  contactPeer,
  traces,
  groupTasks,
  storageSpaceManage,
  jadeSlips,
  instructions,
}

/// 某个主菜单（消息 / 通讯录 / 储物袋）自己的右栏状态。
///
/// 三个菜单各留一份，切走时不拆掉对应 Navigator，再回来还是上次的页面。
class _DeskSlot {
  _DeskSlot({
    required this.mode,
    required this.rightPanel,
  }) {
    routeArgs = _RouteArgs.fromSlot(this);
  }

  final _LeftPanelMode mode;
  _RightPanelView rightPanel;
  ConversationSelection? selected;
  ConversationSelection? lastConversation;
  RemoteAgent? contactAgent;
  Channel? contactGroup;
  PairedPeer? contactPeer;
  String? storageSpace;
  String? tracesChannelId;
  String? taskChannelId;
  String? taskChannelName;
  String? taskGroupId;
  _RightPanelView? previousPanel;
  int navGeneration = 0;
  late _RouteArgs routeArgs;

  bool get storageRecentSelected =>
      rightPanel == _RightPanelView.storageSpaceManage && storageSpace == null;
}

/// 右栏 Navigator 初次生成路由时用的快照。之后不再跟着别的菜单变。
class _RouteArgs {
  _RouteArgs({
    required this.mode,
    required this.panel,
    this.selected,
    this.contactAgent,
    this.contactGroup,
    this.contactPeer,
    this.storageSpace,
    this.tracesChannelId,
    this.taskChannelId,
    this.taskChannelName,
    this.taskGroupId,
    this.showChatBack = false,
  });

  factory _RouteArgs.fromSlot(_DeskSlot slot) {
    return _RouteArgs(
      mode: slot.mode,
      panel: slot.rightPanel,
      selected: slot.selected,
      contactAgent: slot.contactAgent,
      contactGroup: slot.contactGroup,
      contactPeer: slot.contactPeer,
      storageSpace: slot.storageSpace,
      tracesChannelId: slot.tracesChannelId,
      taskChannelId: slot.taskChannelId,
      taskChannelName: slot.taskChannelName,
      taskGroupId: slot.taskGroupId,
      showChatBack: slot.previousPanel != null,
    );
  }

  final _LeftPanelMode mode;
  final _RightPanelView panel;
  final ConversationSelection? selected;
  final RemoteAgent? contactAgent;
  final Channel? contactGroup;
  final PairedPeer? contactPeer;
  final String? storageSpace;
  final String? tracesChannelId;
  final String? taskChannelId;
  final String? taskChannelName;
  final String? taskGroupId;
  final bool showChatBack;
}

/// Describes one item in the icon sidebar.
class _SidebarItemDef {
  final IconData icon;
  final String tooltip;
  final Color Function(BuildContext) colorBuilder;
  final VoidCallback onTap;
  final bool showUpdateBadge;

  const _SidebarItemDef({
    required this.icon,
    required this.tooltip,
    required this.colorBuilder,
    required this.onTap,
    this.showUpdateBadge = false,
  });
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  StreamSubscription? _peerEventSub;
  StreamSubscription? _peerListChangedSub;
  late final Map<_LeftPanelMode, _RightPanelNavigatorObserver> _navObservers;

  @override
  void initState() {
    super.initState();
    _navObservers = {
      for (final mode in _LeftPanelMode.values)
        mode: _RightPanelNavigatorObserver(() => _onRightPanelRootPopped(mode)),
    };
    ChatNavigationService.instance.setDesktopHandler(_onConversationSelected);
    // 监听 peer 事件，删除 peer 后右面板切回空
    _peerEventSub = PeerConnectionManager.instance.events.listen((event) {
      final selected = _slots[_LeftPanelMode.conversations]!.selected;
      if (event.type == PeerConnectionEventType.disconnected &&
          selected?.peerId == event.peerId) {
        _resetIfSelectedPeerRemoved(event.peerId);
      }
    });

    // 监听设备列表变化（删除配对后），若当前选中的 peer 已不存在则清空右面板
    _peerListChangedSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) {
      _resetIfSelectedPeerRemoved(
        _slots[_LeftPanelMode.conversations]!.selected?.peerId,
      );
      _resetIfContactPeerRemoved();
    });

    // 首次设密登录后：首帧自动打开惜宝聊天页引导配置 AI 模型（一次性标记）。
    // 随后检测本机 Agent Hub：已安装则提示加入，未安装则引导安装。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        LoggerService().info('DesktopHome postFrame start', tag: 'HomeBoot');
        try {
          await _maybeOpenSheFirstRun();
          LoggerService().info('_maybeOpenSheFirstRun done', tag: 'HomeBoot');
          if (!mounted) return;
          await maybePromptLocalAgentHub(context);
          LoggerService().info('maybePromptLocalAgentHub done', tag: 'HomeBoot');
        } catch (e, stack) {
          LoggerService().error(
            'DesktopHome postFrame failed',
            tag: 'HomeBoot',
            error: e,
            stackTrace: stack,
          );
        }
      }());
    });
  }

  /// 首次设密后的首登：若 She 尚无 LLM 主模型，自动打开惜宝聊天页展示配置引导。
  /// 标记无论是否命中都清除（一次性），已配好模型的老用户不弹开，行为不变。
  Future<void> _maybeOpenSheFirstRun() async {
    if (!mounted) return;
    final pending = await OnboardingService().consumeFirstEntryPending();
    if (!pending || !mounted) return;
    final db = getIt<LocalDatabaseService>();
    final agent = await db.getRemoteAgentById(SheService.sheId);
    if (!mounted) return;
    // 已配好主模型（非新装/重复触发）→ 落回常规主界面。
    if (agent != null && agent.isLocal) return;
    _openSheChat();
  }

  /// 若指定 peerId 正是当前选中的会话且已从存储中删除，则把右面板切回空，
  /// 避免 FutureBuilder 因找不到 peer 而一直转圈。
  void _resetIfSelectedPeerRemoved(String? peerId) {
    final slot = _slots[_LeftPanelMode.conversations]!;
    if (peerId == null || slot.selected?.peerId != peerId) return;
    PeerConnectionManager.instance.getAllPeers().then((peers) {
      if (mounted &&
          slot.selected?.peerId == peerId &&
          !peers.any((p) => p.id == peerId)) {
        setState(() {
          slot.selected = null;
          if (slot.lastConversation?.peerId == peerId) {
            slot.lastConversation = null;
          }
          slot.rightPanel = _RightPanelView.empty;
          _publishRoute(slot);
        });
      }
    });
  }

  void _resetIfContactPeerRemoved() {
    final slot = _slots[_LeftPanelMode.contacts]!;
    final peerId = slot.contactPeer?.id;
    if (peerId == null || slot.rightPanel != _RightPanelView.contactPeer) {
      return;
    }
    PeerConnectionManager.instance.getAllPeers().then((peers) {
      if (mounted &&
          slot.contactPeer?.id == peerId &&
          !peers.any((p) => p.id == peerId)) {
        _clearContactDetail(reloadList: true);
      }
    });
  }

  @override
  void dispose() {
    ChatNavigationService.instance.setDesktopHandler(null);
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    removeLocalAgentHubNudge();
    FloatingPanelManager.instance.closeAll();
    NativeWindowService.instance.closeAll();
    super.dispose();
  }

  double _leftPanelWidth = 320;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<ContactsScreenState> _contactsKey =
      GlobalKey<ContactsScreenState>();
  final GlobalKey<StorageSpaceListPanelState> _storageKey =
      GlobalKey<StorageSpaceListPanelState>();

  _LeftPanelMode _leftMode = _LeftPanelMode.conversations;
  bool _settingsOpen = false;

  /// 每个主菜单一份右栏。切菜单只改 [_leftMode]，不重建另外两个 Navigator。
  final Map<_LeftPanelMode, _DeskSlot> _slots = {
    _LeftPanelMode.conversations: _DeskSlot(
      mode: _LeftPanelMode.conversations,
      rightPanel: _RightPanelView.empty,
    ),
    _LeftPanelMode.contacts: _DeskSlot(
      mode: _LeftPanelMode.contacts,
      rightPanel: _RightPanelView.empty,
    ),
    _LeftPanelMode.storage: _DeskSlot(
      mode: _LeftPanelMode.storage,
      rightPanel: _RightPanelView.storageSpaceManage,
    ),
  };

  static const double _minLeftPanelWidth = 240;
  static const double _maxLeftPanelWidth = 480;
  static const double _sidebarWidth = 56;

  _DeskSlot get _active => _slots[_leftMode]!;

  String? _contactIdOf(_DeskSlot slot) {
    switch (slot.rightPanel) {
      case _RightPanelView.contactAgent:
        return slot.contactAgent?.id;
      case _RightPanelView.contactGroup:
        return slot.contactGroup?.id;
      case _RightPanelView.contactPeer:
        return slot.contactPeer?.id;
      default:
        return null;
    }
  }

  bool _isStorageDetail(_DeskSlot slot) =>
      slot.rightPanel == _RightPanelView.storageSpaceManage ||
      slot.rightPanel == _RightPanelView.jadeSlips ||
      slot.rightPanel == _RightPanelView.instructions;

  bool _isContactDetail(_DeskSlot slot) =>
      slot.rightPanel == _RightPanelView.contactAgent ||
      slot.rightPanel == _RightPanelView.contactGroup ||
      slot.rightPanel == _RightPanelView.contactPeer;

  /// 同一菜单里换页面时换掉 Navigator。`onGenerateRoute` 只在新建时走一次。
  void _publishRoute(_DeskSlot slot) {
    slot.navGeneration++;
    slot.routeArgs = _RouteArgs.fromSlot(slot);
  }

  void _showMode(_LeftPanelMode mode) {
    if (_leftMode == mode && !_settingsOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _settingsOpen = false;
      _leftMode = mode;
    });
  }

  void _onConversationSelected(ConversationSelection selection) {
    if (_leftMode != _LeftPanelMode.conversations || _settingsOpen) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() {
      _settingsOpen = false;
      _leftMode = _LeftPanelMode.conversations;
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.previousPanel = null;
      slot.selected = selection;
      slot.lastConversation = selection;
      slot.rightPanel = _RightPanelView.chat;
      _publishRoute(slot);
    });
  }

  void _onChatClose() {
    setState(() {
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.selected = null;
      slot.lastConversation = null;
      // Return to the previous panel (e.g. search) if there was one,
      // otherwise go to empty.
      slot.rightPanel = slot.previousPanel ?? _RightPanelView.empty;
      slot.previousPanel = null;
      _publishRoute(slot);
    });
    _reloadAgents();
  }

  void _onShowTraces(String? channelId) {
    setState(() {
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.previousPanel = _RightPanelView.chat;
      slot.tracesChannelId = channelId;
      slot.rightPanel = _RightPanelView.traces;
      _publishRoute(slot);
    });
  }

  void _onTracesBack() {
    setState(() {
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.rightPanel = _RightPanelView.chat;
      slot.previousPanel = null;
      slot.tracesChannelId = null;
      _publishRoute(slot);
    });
  }

  void _onShowGroupTasks(
    String channelId,
    String channelName,
    String groupId,
  ) {
    setState(() {
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.previousPanel = _RightPanelView.chat;
      slot.taskChannelId = channelId;
      slot.taskChannelName = channelName;
      slot.taskGroupId = groupId;
      slot.rightPanel = _RightPanelView.groupTasks;
      _publishRoute(slot);
    });
  }

  void _onGroupTasksBack() {
    setState(() {
      final slot = _slots[_LeftPanelMode.conversations]!;
      slot.rightPanel = _RightPanelView.chat;
      slot.previousPanel = null;
      slot.taskChannelId = null;
      slot.taskChannelName = null;
      slot.taskGroupId = null;
      _publishRoute(slot);
    });
  }

  void _onSwitchChannel(String channelId, {String? highlightMessageId}) {
    final slot = _slots[_LeftPanelMode.conversations]!;
    final selected = slot.selected;
    if (selected == null) return;
    final agentId = selected.agentId;
    final groupFamilyId = selected.groupFamilyId;
    if (agentId != null) {
      _homeKey.currentState?.rememberAgentChannel(agentId, channelId);
    }
    if (groupFamilyId != null) {
      _homeKey.currentState?.rememberGroupChannel(groupFamilyId, channelId);
    }
    setState(() {
      slot.selected = ConversationSelection(
        agentId: selected.agentId,
        agentName: selected.agentName,
        agentAvatar: selected.agentAvatar,
        channelId: channelId,
        groupFamilyId: selected.groupFamilyId,
        highlightMessageId: highlightMessageId,
      );
      slot.lastConversation = slot.selected;
      _publishRoute(slot);
    });
  }

  void _reloadAgents() {
    _homeKey.currentState?.reloadAgents();
  }

  void _reloadContacts() {
    _contactsKey.currentState?.reload();
  }

  void _reloadStorage() {
    _storageKey.currentState?.reload();
  }

  void _clearContactDetail({bool reloadList = false}) {
    setState(() {
      final slot = _slots[_LeftPanelMode.contacts]!;
      slot.contactAgent = null;
      slot.contactGroup = null;
      slot.contactPeer = null;
      slot.rightPanel = _RightPanelView.empty;
      _publishRoute(slot);
    });
    if (reloadList) _reloadContacts();
  }

  void _onRightPanelRootPopped(_LeftPanelMode mode) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leftMode != mode || _settingsOpen) return;
      final slot = _slots[mode]!;
      if (_isContactDetail(slot)) {
        _clearContactDetail(reloadList: true);
        return;
      }
      if (_isStorageDetail(slot)) {
        // 根路由被关掉时，按当前分区重新铺一页，不要退回「最近」。
        setState(() => _publishRoute(slot));
        _reloadStorage();
      }
    });
  }

  void _showConversations() => _showMode(_LeftPanelMode.conversations);

  /// 侧栏打开惜宝。频道和已读交给聊天页加载，这里不等数据库。
  void _openSheChat() {
    final l10n = AppLocalizations.of(context);
    final home = _homeKey.currentState;
    String? name;
    String? avatar;
    final agents = home?.agents;
    if (agents != null) {
      for (final agent in agents) {
        if (agent.id == SheService.sheId) {
          name = agent.name;
          avatar = agent.avatar;
          break;
        }
      }
    }
    _onConversationSelected(ConversationSelection(
      agentId: SheService.sheId,
      agentName: name != null
          ? SheService.resolveDisplayName(name, l10n.she_name)
          : l10n.she_name,
      agentAvatar: avatar ?? SheService.sheAvatar,
      channelId: home?.cachedAgentChannelId(SheService.sheId),
    ));
  }

  void _showContacts() => _showMode(_LeftPanelMode.contacts);

  void _showStorage() => _showMode(_LeftPanelMode.storage);

  void _showPanel(_RightPanelView panel) {
    if (panel == _RightPanelView.settings) {
      if (_settingsOpen) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _settingsOpen = true);
      return;
    }
    final slot = _active;
    if (!_settingsOpen && slot.rightPanel == panel) return;
    setState(() {
      _settingsOpen = false;
      slot.rightPanel = panel;
      if (panel != _RightPanelView.chat) {
        slot.selected = null;
      }
      if (!_isContactDetail(slot)) {
        slot.contactAgent = null;
        slot.contactGroup = null;
        slot.contactPeer = null;
      }
      _publishRoute(slot);
    });
  }

  void _onStorageRecentSelected() {
    setState(() {
      final slot = _slots[_LeftPanelMode.storage]!;
      slot.storageSpace = null;
      slot.selected = null;
      slot.rightPanel = _RightPanelView.storageSpaceManage;
      _publishRoute(slot);
    });
  }

  void _onStorageSpaceSelected(String space) {
    setState(() {
      final slot = _slots[_LeftPanelMode.storage]!;
      slot.storageSpace = space;
      slot.selected = null;
      slot.rightPanel = switch (space) {
        StoreSpace.notes => _RightPanelView.jadeSlips,
        StoreSpace.instructions => _RightPanelView.instructions,
        _ => _RightPanelView.storageSpaceManage,
      };
      _publishRoute(slot);
    });
  }

  void _onContactAgentSelected(RemoteAgent agent) {
    setState(() {
      final slot = _slots[_LeftPanelMode.contacts]!;
      slot.contactAgent = agent;
      slot.contactGroup = null;
      slot.contactPeer = null;
      slot.selected = null;
      slot.rightPanel = _RightPanelView.contactAgent;
      _publishRoute(slot);
    });
  }

  void _onContactGroupSelected(Channel group) {
    setState(() {
      final slot = _slots[_LeftPanelMode.contacts]!;
      slot.contactGroup = group;
      slot.contactAgent = null;
      slot.contactPeer = null;
      slot.selected = null;
      slot.rightPanel = _RightPanelView.contactGroup;
      _publishRoute(slot);
    });
  }

  void _onContactPeerSelected(PairedPeer peer) {
    setState(() {
      final slot = _slots[_LeftPanelMode.contacts]!;
      slot.contactPeer = peer;
      slot.contactAgent = null;
      slot.contactGroup = null;
      slot.selected = null;
      slot.rightPanel = _RightPanelView.contactPeer;
      _publishRoute(slot);
    });
  }

  void _onDevicePaired(PairedPeer peer) {
    _reloadAgents();
    _reloadContacts();
    if (_leftMode == _LeftPanelMode.contacts ||
        !ProductFeatures.deviceChatUiEnabled) {
      _onContactPeerSelected(peer);
      return;
    }
    _onConversationSelected(ConversationSelection(peerId: peer.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // WeChat-style icon sidebar
          _buildSidebar(),

          // 三个主菜单都留在树上，切走再回来不用重头渲染。
          SizedBox(
            width: _leftPanelWidth,
            child: IndexedStack(
              index: _leftMode.index,
              sizing: StackFit.expand,
              children: [
                HomeScreen(
                  key: _homeKey,
                  embedded: true,
                  selectedConversation:
                      _slots[_LeftPanelMode.conversations]!.selected,
                  onConversationSelected: _onConversationSelected,
                  onAddAgent: () => _showPanel(_RightPanelView.addAgent),
                  onCreateGroup: () => _showPanel(_RightPanelView.createGroup),
                  onPairDevice: () => _showPanel(_RightPanelView.pairDevice),
                ),
                ContactsScreen(
                  key: _contactsKey,
                  embedded: true,
                  selectedContactId:
                      _contactIdOf(_slots[_LeftPanelMode.contacts]!),
                  onAgentSelected: _onContactAgentSelected,
                  onGroupSelected: _onContactGroupSelected,
                  onPeerSelected: _onContactPeerSelected,
                  onAddAgent: () => _showPanel(_RightPanelView.addAgent),
                  onCreateGroup: () => _showPanel(_RightPanelView.createGroup),
                  onPairDevice: () =>
                      _showPanel(_RightPanelView.pairDeviceInput),
                ),
                StorageSpaceListPanel(
                  key: _storageKey,
                  recentSelected:
                      _slots[_LeftPanelMode.storage]!.storageRecentSelected,
                  selectedSpace: _slots[_LeftPanelMode.storage]!.storageSpace,
                  onRecentSelected: _onStorageRecentSelected,
                  onSpaceSelected: _onStorageSpaceSelected,
                ),
              ],
            ),
          ),

          // Resizable divider
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              setState(() {
                _leftPanelWidth = (_leftPanelWidth + details.delta.dx)
                    .clamp(_minLeftPanelWidth, _maxLeftPanelWidth);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: SizedBox(
                width: 12,
                child: Center(
                  child: Container(
                    width: 1,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          ),

          // 每个主菜单一个 Navigator。菜单内换页才换 key；切到别的主菜单再回来，
          // 已打开的页面（含 push 上去的子页）还在。
          Expanded(
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IndexedStack(
                    index: _leftMode.index,
                    sizing: StackFit.expand,
                    children: [
                      for (final mode in _LeftPanelMode.values)
                        _modeNavigator(mode),
                    ],
                  ),
                  if (_settingsOpen)
                    Navigator(
                      key: const ValueKey('desktop_settings'),
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeNavigator(_LeftPanelMode mode) {
    final slot = _slots[mode]!;
    final args = slot.routeArgs;
    return Navigator(
      key: ValueKey('desk_nav_${mode.name}_${slot.navGeneration}'),
      observers: [_navObservers[mode]!],
      onGenerateRoute: (_) {
        return MaterialPageRoute<void>(
          builder: (_) => _buildRightPanel(args),
        );
      },
    );
  }

  /// The root widget of one main-menu navigator.
  Widget _buildRightPanel(_RouteArgs args) {
    switch (args.panel) {
      case _RightPanelView.chat:
        final selected = args.selected;
        if (selected != null) {
          // P2P 设备聊天
          if (selected.peerId != null) {
            if (!ProductFeatures.deviceChatUiEnabled) {
              return _buildEmptyState(args.mode);
            }
            return FutureBuilder<PairedPeer?>(
              key: ValueKey('peer_${selected.peerId}'),
              future: PeerConnectionManager.instance.getAllPeers().then(
                (peers) => peers.where((p) => p.id == selected.peerId).firstOrNull,
              ),
              builder: (context, snapshot) {
                // 仅在加载中显示转圈
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                // 加载完成但 peer 不存在（已被删除）→ 回到空状态，避免一直白屏转圈
                final peer = snapshot.data;
                if (peer == null) {
                  return _buildEmptyState(args.mode);
                }
                return PeerChatScreen(
                  key: ValueKey(selected.key),
                  peer: peer,
                  embedded: true,
                  highlightMessageId: selected.highlightMessageId,
                  onAgentSelected: (agent) {
                    _onConversationSelected(ConversationSelection(
                      agentId: agent.id,
                      agentName: agent.name,
                      agentAvatar: agent.avatar,
                    ));
                  },
                );
              },
            );
          }
          // 普通 Agent/Group 聊天
          return ChatScreen(
            key: ValueKey(selected.key),
            agentId: selected.agentId,
            agentName: selected.agentName,
            agentAvatar: selected.agentAvatar,
            channelId: selected.channelId,
            highlightMessageId: selected.highlightMessageId,
            embedded: true,
            showBackButton: args.showChatBack,
            onClose: _onChatClose,
            onSwitchChannel: _onSwitchChannel,
            onShowTraces: _onShowTraces,
            onShowGroupTasks: _onShowGroupTasks,
          );
        }
        return _buildEmptyState(args.mode);

      case _RightPanelView.settings:
        return const SettingsScreen();

      case _RightPanelView.addAgent:
        return AddRemoteAgentScreen(
          onDone: () {
            _reloadAgents();
            _reloadContacts();
            _showPanel(_RightPanelView.empty);
          },
        );

      case _RightPanelView.createGroup:
        return CreateGroupScreen(
          onGroupCreated: (channelId) {
            _reloadAgents();
            _reloadContacts();
            if (_leftMode == _LeftPanelMode.contacts) {
              _showPanel(_RightPanelView.empty);
              return;
            }
            // After creating a group, switch to the group chat.
            _onConversationSelected(ConversationSelection(
              channelId: channelId,
              groupFamilyId: channelId,
            ));
          },
        );

      case _RightPanelView.pairDevice:
        return PeerPairingScreen(
          // 桌面端没有摄像头，`mobile_scanner` 也没有桌面实现 —— 「我连它」的第一项
          // 在这块屏幕上必然是个死入口。所以桌面面板仍旧落在「它连我」：把二维码
          // 摆出来让手机扫，本来就是桌面配对的常态流程。
          initialTab: PeerPairingTab.beConnected,
          onPaired: _onDevicePaired,
        );

      case _RightPanelView.pairDeviceInput:
        // 通讯录「添加配对设备」在桌面直接进「输入配对信息」，不再绕 tab。
        return PeerManualInputScreen(onPaired: _onDevicePaired);

      case _RightPanelView.contactAgent:
        final agent = args.contactAgent;
        if (agent == null) return _buildEmptyState(args.mode);
        return RemoteAgentDetailScreen(
          key: ValueKey('contact_agent_${agent.id}'),
          agent: agent,
        );

      case _RightPanelView.contactGroup:
        final group = args.contactGroup;
        if (group == null) return _buildEmptyState(args.mode);
        return GroupDetailScreen(
          key: ValueKey('contact_group_${group.id}'),
          channel: group,
        );

      case _RightPanelView.contactPeer:
        final peer = args.contactPeer;
        if (peer == null) return _buildEmptyState(args.mode);
        return PeerSettingsScreen(
          key: ValueKey('contact_peer_${peer.id}'),
          peer: peer,
        );

      case _RightPanelView.traces:
        return ChannelTraceScreen(
          channelId: args.tracesChannelId,
          channelName: args.selected?.agentName,
          onBack: _onTracesBack,
        );

      case _RightPanelView.groupTasks:
        return GroupTaskListScreen(
          groupId: args.taskGroupId ?? args.taskChannelId ?? '',
          channelId: args.taskChannelId ?? '',
          channelName: args.taskChannelName ?? '',
          onBack: _onGroupTasksBack,
        );

      case _RightPanelView.storageSpaceManage:
        // 左侧面板已列出「最近 / 我的 / 智能体」入口，右侧不再重复放 Tab。
        return StorageSpaceManageScreen(
          initialSpace: args.storageSpace,
          showTabHeader: false,
        );

      case _RightPanelView.jadeSlips:
        return const JadeSlipScreen(embedded: true);

      case _RightPanelView.instructions:
        return const InstructionSetScreen(embedded: true);

      case _RightPanelView.empty:
        return _buildEmptyState(args.mode);
    }
  }

  /// WeChat-style narrow icon sidebar on the far left.
  Widget _buildSidebar() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sidebarBg = colorScheme.surfaceContainerHighest;
    // 比 onSurfaceVariant 略深，避免侧栏图标发灰难以辨认。
    final iconColor = Color.lerp(
      colorScheme.onSurfaceVariant,
      colorScheme.onSurface,
      0.4,
    )!;
    final activeColor = colorScheme.primary;

    // Top section items (always visible, never collapsed)
    final topItems = [
      _SidebarItemDef(
        icon: Icons.chat_bubble,
        tooltip: l10n.drawer_myProfile,
        colorBuilder: (_) =>
            _leftMode == _LeftPanelMode.conversations && !_settingsOpen
            ? activeColor
            : iconColor,
        onTap: _showConversations,
      ),
      _SidebarItemDef(
        icon: Icons.contacts_outlined,
        tooltip: l10n.drawer_contacts,
        colorBuilder: (_) =>
            _leftMode == _LeftPanelMode.contacts && !_settingsOpen
            ? activeColor
            : iconColor,
        onTap: _showContacts,
      ),
      _SidebarItemDef(
        icon: Icons.inventory_2_outlined,
        tooltip: l10n.storage_title,
        colorBuilder: (_) =>
            _leftMode == _LeftPanelMode.storage && !_settingsOpen
            ? activeColor
            : iconColor,
        onTap: _showStorage,
      ),
    ];

    // Bottom section: divider + settings
    final bottomItems = [
      _SidebarItemDef(
        icon: Icons.horizontal_rule, // sentinel → rendered as Divider
        tooltip: '',
        colorBuilder: (_) => Colors.transparent,
        onTap: () {},
      ),
      _SidebarItemDef(
        icon: Icons.settings_outlined,
        tooltip: l10n.drawer_settings,
        colorBuilder: (_) =>
            _settingsOpen ? activeColor : iconColor,
        onTap: () {
          UpdateService().dismissSettingsIconBadge();
          _showPanel(_RightPanelView.settings);
        },
        showUpdateBadge: true,
      ),
    ];

    return Container(
      width: _sidebarWidth,
      color: sidebarBg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableHeight = constraints.maxHeight;
          const double topPadding = 12.0;
          const double logoHeight = 52.0;
          const double itemHeight = 42.0;
          const double dividerHeight = 17.0;
          const double bottomPadding = 12.0;

          final topItemsHeight = topItems.length * itemHeight;
          final bottomHeight = dividerHeight + itemHeight;
          final spacerHeight = (availableHeight -
                  topPadding -
                  logoHeight -
                  topItemsHeight -
                  bottomPadding -
                  bottomHeight)
              .clamp(0.0, double.infinity);

          Widget buildItem(_SidebarItemDef item) {
            final icon = _SidebarIcon(
              icon: item.icon,
              tooltip: item.tooltip,
              color: item.colorBuilder(context),
              onTap: item.onTap,
            );
            if (item.showUpdateBadge) {
              return SettingsUpdateBadge(child: icon);
            }
            return icon;
          }

          return Column(
            children: [
              const SizedBox(height: 12),
              Tooltip(
                message: l10n.she_name,
                preferBelow: false,
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: _openSheChat,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/images/shepaw_icon.png',
                        width: 36,
                        height: 36,
                      ),
                    ),
                  ),
                ),
              ),
              ...topItems.map(buildItem),
              SizedBox(height: spacerHeight),
              for (final item in bottomItems)
                if (item.icon == Icons.horizontal_rule)
                  const Divider(indent: 12, endIndent: 12, height: 17)
                else
                  buildItem(item),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(_LeftPanelMode mode) {
    final l10n = AppLocalizations.of(context);
    final IconData icon;
    final String label;
    switch (mode) {
      case _LeftPanelMode.contacts:
        icon = Icons.contacts_outlined;
        label = l10n.contacts_title;
      case _LeftPanelMode.storage:
        icon = Icons.inventory_2_outlined;
        label = l10n.storage_title;
      case _LeftPanelMode.conversations:
        icon = Icons.chat_bubble_outline;
        label = l10n.home_noMessages;
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }
}

/// Observes the right-panel Navigator so that when a detail page pops itself
/// (e.g. after delete), we can reset to the empty contacts state.
class _RightPanelNavigatorObserver extends NavigatorObserver {
  final VoidCallback onRootPopped;

  _RightPanelNavigatorObserver(this.onRootPopped);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) {
      onRootPopped();
    }
  }
}

/// A single icon button in the sidebar.
class _SidebarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _SidebarIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }
}
