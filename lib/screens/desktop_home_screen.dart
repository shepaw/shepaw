import 'dart:async';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/conversation_selection.dart';
import '../models/remote_agent.dart';
import '../l10n/app_localizations.dart';
import '../config/product_features.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_chat_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'channel_trace_screen.dart';
import 'group_workflow_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'group_detail_screen.dart';
import 'remote_agent_detail_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'storage_space_screen.dart';
import 'storage_snapshots_screen.dart';
import 'storage_space_manage_screen.dart';
import 'storage_import_screen.dart';
import 'storage_advanced_screen.dart';
import 'storage_nexuspouch_screen.dart';
import 'storage_browser_screen.dart';
import '../widgets/storage/storage_space_hub.dart';
import '../utils/layout_utils.dart';
import '../services/native_window_service.dart';
import '../services/chat_navigation_service.dart';

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
  contactAgent,
  contactGroup,
  contactPeer,
  traces,
  groupWorkflow,
  storageSnapshots,
  storageSpaceManage,
  storagePeerBrowse,
  storageNas,
  storageImport,
  storageAdvanced,
}

/// Describes one item in the icon sidebar.
class _SidebarItemDef {
  final IconData icon;
  final String tooltip;
  final Color Function(BuildContext) colorBuilder;
  final VoidCallback onTap;

  const _SidebarItemDef({
    required this.icon,
    required this.tooltip,
    required this.colorBuilder,
    required this.onTap,
  });
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  StreamSubscription? _peerEventSub;
  StreamSubscription? _peerListChangedSub;
  late final _RightPanelNavigatorObserver _navObserver;

  @override
  void initState() {
    super.initState();
    _navObserver = _RightPanelNavigatorObserver(_onRightPanelRootPopped);
    ChatNavigationService.instance.setDesktopHandler(_onConversationSelected);
    // 监听 peer 事件，删除 peer 后右面板切回空
    _peerEventSub = PeerConnectionManager.instance.events.listen((event) {
      if (event.type == PeerConnectionEventType.disconnected &&
          _selected?.peerId == event.peerId) {
        _resetIfSelectedPeerRemoved(event.peerId);
      }
    });

    // 监听设备列表变化（删除配对后），若当前选中的 peer 已不存在则清空右面板
    _peerListChangedSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) {
      _resetIfSelectedPeerRemoved(_selected?.peerId);
      _resetIfContactPeerRemoved();
      _resetIfStoragePeerRemoved();
    });
  }

  /// 若指定 peerId 正是当前选中的会话且已从存储中删除，则把右面板切回空，
  /// 避免 FutureBuilder 因找不到 peer 而一直转圈。
  void _resetIfSelectedPeerRemoved(String? peerId) {
    if (peerId == null || _selected?.peerId != peerId) return;
    PeerConnectionManager.instance.getAllPeers().then((peers) {
      if (mounted &&
          _selected?.peerId == peerId &&
          !peers.any((p) => p.id == peerId)) {
        setState(() {
          _selected = null;
          _rightPanel = _RightPanelView.empty;
          _navGeneration++;
        });
      }
    });
  }

  void _resetIfContactPeerRemoved() {
    final peerId = _contactPeer?.id;
    if (peerId == null || _rightPanel != _RightPanelView.contactPeer) return;
    PeerConnectionManager.instance.getAllPeers().then((peers) {
      if (mounted &&
          _contactPeer?.id == peerId &&
          !peers.any((p) => p.id == peerId)) {
        _clearContactDetail(reloadList: true);
      }
    });
  }

  void _resetIfStoragePeerRemoved() {
    final peerId = _storagePeer?.id;
    if (peerId == null || _rightPanel != _RightPanelView.storagePeerBrowse) {
      return;
    }
    PeerConnectionManager.instance.getAllPeers().then((peers) {
      if (mounted &&
          _storagePeer?.id == peerId &&
          !peers.any((p) => p.id == peerId)) {
        _showStorage();
        _reloadStorage();
      }
    });
  }

  @override
  void dispose() {
    ChatNavigationService.instance.setDesktopHandler(null);
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    FloatingPanelManager.instance.closeAll();
    NativeWindowService.instance.closeAll();
    super.dispose();
  }

  ConversationSelection? _selected;
  double _leftPanelWidth = 320;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<ContactsScreenState> _contactsKey =
      GlobalKey<ContactsScreenState>();
  final GlobalKey<StorageSpaceHubState> _storageKey =
      GlobalKey<StorageSpaceHubState>();

  _LeftPanelMode _leftMode = _LeftPanelMode.conversations;
  _RightPanelView _rightPanel = _RightPanelView.empty;

  RemoteAgent? _contactAgent;
  Channel? _contactGroup;
  PairedPeer? _contactPeer;
  PairedPeer? _storagePeer;
  StorageBagEntry? _storageEntry;

  String? get _selectedContactId {
    switch (_rightPanel) {
      case _RightPanelView.contactAgent:
        return _contactAgent?.id;
      case _RightPanelView.contactGroup:
        return _contactGroup?.id;
      case _RightPanelView.contactPeer:
        return _contactPeer?.id;
      default:
        return null;
    }
  }

  /// The actual channelId of the chat that triggered the traces view.
  /// May differ from _selected?.channelId when the controller created/loaded
  /// a channel after the initial ConversationSelection was recorded.
  String? _tracesChannelId;

  /// Channel info for the group workflow view.
  String? _workflowChannelId;
  String? _workflowChannelName;

  /// Tracks the panel that was showing before switching to chat,
  /// so the close/back button can return to it (e.g. search → chat → search).
  _RightPanelView? _previousPanel;

  /// Monotonic counter appended to the Navigator's ValueKey so that
  /// each conversation switch creates a fresh Navigator (and therefore a
  /// fresh initial route).  This avoids the problem where
  /// `onGenerateRoute` only fires once for a given Navigator instance.
  int _navGeneration = 0;

  static const double _minLeftPanelWidth = 240;
  static const double _maxLeftPanelWidth = 480;
  static const double _sidebarWidth = 56;

  bool get _isUtilityPanel => _rightPanel == _RightPanelView.settings;

  bool get _isStorageDetailPanel =>
      _rightPanel == _RightPanelView.storageSnapshots ||
      _rightPanel == _RightPanelView.storageSpaceManage ||
      _rightPanel == _RightPanelView.storagePeerBrowse ||
      _rightPanel == _RightPanelView.storageNas ||
      _rightPanel == _RightPanelView.storageImport ||
      _rightPanel == _RightPanelView.storageAdvanced;

  bool get _storageLocalSelected =>
      _leftMode == _LeftPanelMode.storage &&
      _rightPanel == _RightPanelView.storageSpaceManage;

  bool get _storageNasSelected =>
      _leftMode == _LeftPanelMode.storage &&
      _rightPanel == _RightPanelView.storageNas;

  String? get _storageSelectedPeerId =>
      _rightPanel == _RightPanelView.storagePeerBrowse
          ? _storagePeer?.id
          : null;

  bool get _isContactDetailPanel =>
      _rightPanel == _RightPanelView.contactAgent ||
      _rightPanel == _RightPanelView.contactGroup ||
      _rightPanel == _RightPanelView.contactPeer;

  void _onConversationSelected(ConversationSelection selection) {
    setState(() {
      _leftMode = _LeftPanelMode.conversations;
      _previousPanel = null;
      _selected = selection;
      _clearContactSelectionFields();
      _storageEntry = null;
      _storagePeer = null;
      _rightPanel = _RightPanelView.chat;
      _navGeneration++;
    });
  }

  void _onChatClose() {
    setState(() {
      _selected = null;
      // Return to the previous panel (e.g. search) if there was one,
      // otherwise go to empty.
      _rightPanel = _previousPanel ?? _RightPanelView.empty;
      _previousPanel = null;
      _navGeneration++;
    });
    _reloadAgents();
  }

  void _onShowTraces(String? channelId) {
    setState(() {
      _previousPanel = _RightPanelView.chat;
      _tracesChannelId = channelId;
      _rightPanel = _RightPanelView.traces;
      _navGeneration++;
    });
  }

  void _onTracesBack() {
    setState(() {
      _rightPanel = _RightPanelView.chat;
      _previousPanel = null;
      _tracesChannelId = null;
      _navGeneration++;
    });
  }

  void _onShowGroupWorkflow(String channelId, String channelName) {
    setState(() {
      _previousPanel = _RightPanelView.chat;
      _workflowChannelId = channelId;
      _workflowChannelName = channelName;
      _rightPanel = _RightPanelView.groupWorkflow;
      _navGeneration++;
    });
  }

  void _onGroupWorkflowBack() {
    setState(() {
      _rightPanel = _RightPanelView.chat;
      _previousPanel = null;
      _workflowChannelId = null;
      _workflowChannelName = null;
      _navGeneration++;
    });
  }

  void _onSwitchChannel(String channelId, {String? highlightMessageId}) {
    if (_selected == null) return;
    setState(() {
      _selected = ConversationSelection(
        agentId: _selected!.agentId,
        agentName: _selected!.agentName,
        agentAvatar: _selected!.agentAvatar,
        channelId: channelId,
        groupFamilyId: _selected!.groupFamilyId,
        highlightMessageId: highlightMessageId,
      );
      _navGeneration++;
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

  void _clearContactSelectionFields() {
    _contactAgent = null;
    _contactGroup = null;
    _contactPeer = null;
  }

  void _clearContactDetail({bool reloadList = false}) {
    setState(() {
      _clearContactSelectionFields();
      _rightPanel = _RightPanelView.empty;
      _navGeneration++;
    });
    if (reloadList) _reloadContacts();
  }

  void _onRightPanelRootPopped() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isContactDetailPanel) {
        _clearContactDetail(reloadList: true);
        return;
      }
      if (_isStorageDetailPanel && _leftMode == _LeftPanelMode.storage) {
        _showStorage();
        _reloadStorage();
      }
    });
  }

  void _showConversations() {
    setState(() {
      _leftMode = _LeftPanelMode.conversations;
      _clearContactSelectionFields();
      _storageEntry = null;
      _storagePeer = null;
      _selected = null;
      _rightPanel = _RightPanelView.empty;
      _navGeneration++;
    });
  }

  void _showContacts() {
    setState(() {
      _leftMode = _LeftPanelMode.contacts;
      _selected = null;
      _clearContactSelectionFields();
      _storageEntry = null;
      _storagePeer = null;
      _rightPanel = _RightPanelView.empty;
      _navGeneration++;
    });
  }

  void _showStorage() {
    setState(() {
      _leftMode = _LeftPanelMode.storage;
      _selected = null;
      _clearContactSelectionFields();
      // 默认选中本机，与移动端「本机置顶」对齐。
      _storageEntry = null;
      _storagePeer = null;
      _rightPanel = _RightPanelView.storageSpaceManage;
      _navGeneration++;
    });
  }

  void _showPanel(_RightPanelView panel) {
    if (_rightPanel == panel) return; // already showing this panel
    setState(() {
      _rightPanel = panel;
      if (panel != _RightPanelView.chat) {
        _selected = null;
      }
      if (!_isContactDetailPanel) {
        _clearContactSelectionFields();
      }
      if (!_isStorageDetailPanel) {
        _storageEntry = null;
        _storagePeer = null;
      }
      _navGeneration++;
    });
  }

  void _onStorageLocalSelected() {
    setState(() {
      _storagePeer = null;
      _storageEntry = null;
      _selected = null;
      _clearContactSelectionFields();
      _rightPanel = _RightPanelView.storageSpaceManage;
      _navGeneration++;
    });
  }

  void _onStoragePeerSelected(PairedPeer peer) {
    setState(() {
      _storagePeer = peer;
      _storageEntry = null;
      _selected = null;
      _clearContactSelectionFields();
      _rightPanel = _RightPanelView.storagePeerBrowse;
      _navGeneration++;
    });
  }

  void _onStorageEntrySelected(StorageBagEntry entry) {
    setState(() {
      _storageEntry = entry;
      _storagePeer = null;
      _selected = null;
      _clearContactSelectionFields();
      _rightPanel = switch (entry) {
        StorageBagEntry.snapshots => _RightPanelView.storageSnapshots,
        StorageBagEntry.space => _RightPanelView.storageSpaceManage,
        StorageBagEntry.nas => _RightPanelView.storageNas,
        StorageBagEntry.import => _RightPanelView.storageImport,
        StorageBagEntry.advanced => _RightPanelView.storageAdvanced,
      };
      _navGeneration++;
    });
  }

  void _onContactAgentSelected(RemoteAgent agent) {
    setState(() {
      _contactAgent = agent;
      _contactGroup = null;
      _contactPeer = null;
      _storageEntry = null;
      _storagePeer = null;
      _selected = null;
      _rightPanel = _RightPanelView.contactAgent;
      _navGeneration++;
    });
  }

  void _onContactGroupSelected(Channel group) {
    setState(() {
      _contactGroup = group;
      _contactAgent = null;
      _contactPeer = null;
      _storageEntry = null;
      _storagePeer = null;
      _selected = null;
      _rightPanel = _RightPanelView.contactGroup;
      _navGeneration++;
    });
  }

  void _onContactPeerSelected(PairedPeer peer) {
    setState(() {
      _contactPeer = peer;
      _contactAgent = null;
      _contactGroup = null;
      _storageEntry = null;
      _storagePeer = null;
      _selected = null;
      _rightPanel = _RightPanelView.contactPeer;
      _navGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // WeChat-style icon sidebar
          _buildSidebar(),

          // Conversation / contacts / storage list panel
          SizedBox(
            width: _leftPanelWidth,
            child: switch (_leftMode) {
              _LeftPanelMode.conversations => HomeScreen(
                  key: _homeKey,
                  embedded: true,
                  selectedConversation: _selected,
                  onConversationSelected: _onConversationSelected,
                  onAddAgent: () => _showPanel(_RightPanelView.addAgent),
                  onCreateGroup: () => _showPanel(_RightPanelView.createGroup),
                  onPairDevice: () => _showPanel(_RightPanelView.pairDevice),
                ),
              _LeftPanelMode.contacts => ContactsScreen(
                  key: _contactsKey,
                  embedded: true,
                  selectedContactId: _selectedContactId,
                  onAgentSelected: _onContactAgentSelected,
                  onGroupSelected: _onContactGroupSelected,
                  onPeerSelected: _onContactPeerSelected,
                  onAddAgent: () => _showPanel(_RightPanelView.addAgent),
                  onCreateGroup: () => _showPanel(_RightPanelView.createGroup),
                  onPairDevice: () => _showPanel(_RightPanelView.pairDevice),
                ),
              _LeftPanelMode.storage => StorageSpaceHub(
                  key: _storageKey,
                  embedded: true,
                  localSelected: _storageLocalSelected,
                  selectedPeerId: _storageSelectedPeerId,
                  nasSelected: _storageNasSelected,
                  onLocalSelected: _onStorageLocalSelected,
                  onPeerSelected: _onStoragePeerSelected,
                  onNasSelected: () =>
                      _onStorageEntrySelected(StorageBagEntry.nas),
                  footer: _buildStorageToolFooter(),
                ),
            },
          ),

          // Resizable divider
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              setState(() {
                _leftPanelWidth = (_leftPanelWidth + details.delta.dx)
                    .clamp(_minLeftPanelWidth, _maxLeftPanelWidth);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                width: 1,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),

          // Right panel — uses a nested Navigator so that pages pushed
          // inside it (e.g. Settings sub-pages) stay within this panel.
          // The ValueKey includes _navGeneration so that switching
          // conversations creates a fresh Navigator with a new initial
          // route, rather than trying to mutate the old one.
          Expanded(
            child: ClipRect(
              child: Navigator(
                key: ValueKey('nav_$_navGeneration'),
                observers: [_navObserver],
                onGenerateRoute: (_) {
                  return MaterialPageRoute(
                    builder: (_) => _buildRightPanelRoot(),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The root widget of the right-panel navigator.
  Widget _buildRightPanelRoot() {
    switch (_rightPanel) {
      case _RightPanelView.chat:
        if (_selected != null) {
          // P2P 设备聊天
          if (_selected!.peerId != null) {
            if (!ProductFeatures.deviceChatUiEnabled) {
              return _buildEmptyState();
            }
            return FutureBuilder<PairedPeer?>(
              key: ValueKey('peer_${_selected!.peerId}'),
              future: PeerConnectionManager.instance.getAllPeers().then(
                (peers) => peers.where((p) => p.id == _selected!.peerId).firstOrNull,
              ),
              builder: (context, snapshot) {
                // 仅在加载中显示转圈
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                // 加载完成但 peer 不存在（已被删除）→ 回到空状态，避免一直白屏转圈
                final peer = snapshot.data;
                if (peer == null) {
                  return _buildEmptyState();
                }
                return PeerChatScreen(
                  key: ValueKey(_selected!.key),
                  peer: peer,
                  embedded: true,
                  highlightMessageId: _selected!.highlightMessageId,
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
            key: ValueKey(_selected!.key),
            agentId: _selected!.agentId,
            agentName: _selected!.agentName,
            agentAvatar: _selected!.agentAvatar,
            channelId: _selected!.channelId,
            highlightMessageId: _selected!.highlightMessageId,
            embedded: true,
            showBackButton: _previousPanel != null,
            onClose: _onChatClose,
            onSwitchChannel: _onSwitchChannel,
            onShowTraces: _onShowTraces,
            onShowGroupWorkflow: _onShowGroupWorkflow,
          );
        }
        return _buildEmptyState();

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
          onPaired: (peer) {
            _reloadAgents();
            _reloadContacts();
            if (_leftMode == _LeftPanelMode.contacts ||
                !ProductFeatures.deviceChatUiEnabled) {
              _onContactPeerSelected(peer);
              return;
            }
            _onConversationSelected(ConversationSelection(peerId: peer.id));
          },
        );

      case _RightPanelView.contactAgent:
        final agent = _contactAgent;
        if (agent == null) return _buildEmptyState();
        return RemoteAgentDetailScreen(
          key: ValueKey('contact_agent_${agent.id}'),
          agent: agent,
        );

      case _RightPanelView.contactGroup:
        final group = _contactGroup;
        if (group == null) return _buildEmptyState();
        return GroupDetailScreen(
          key: ValueKey('contact_group_${group.id}'),
          channel: group,
        );

      case _RightPanelView.contactPeer:
        final peer = _contactPeer;
        if (peer == null) return _buildEmptyState();
        return PeerSettingsScreen(
          key: ValueKey('contact_peer_${peer.id}'),
          peer: peer,
        );

      case _RightPanelView.traces:
        return ChannelTraceScreen(
          channelId: _tracesChannelId,
          channelName: _selected?.agentName,
          onBack: _onTracesBack,
        );

      case _RightPanelView.groupWorkflow:
        return GroupWorkflowScreen(
          channelId: _workflowChannelId ?? '',
          channelName: _workflowChannelName ?? '',
          onBack: _onGroupWorkflowBack,
        );

      case _RightPanelView.storageSnapshots:
        return const StorageSnapshotsScreen();

      case _RightPanelView.storageSpaceManage:
        return const StorageSpaceManageScreen();

      case _RightPanelView.storagePeerBrowse:
        final peer = _storagePeer;
        if (peer == null) return _buildEmptyState();
        return StorageBrowserScreen(
          key: ValueKey('storage_peer_${peer.id}'),
          deviceId: peer.fingerprint,
          deviceName: peer.deviceName,
          peerId: peer.id,
          readOnly: true,
        );

      case _RightPanelView.storageNas:
        return const StorageNexuspouchScreen();

      case _RightPanelView.storageImport:
        return const StorageImportScreen();

      case _RightPanelView.storageAdvanced:
        return const StorageAdvancedScreen();

      case _RightPanelView.empty:
        return _buildEmptyState();
    }
  }

  List<Widget> _buildStorageToolFooter() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    Widget tile({
      required StorageBagEntry entry,
      required IconData icon,
      required String title,
      required String subtitle,
    }) {
      final selected = _storageEntry == entry;
      return ListTile(
        selected: selected,
        selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
        leading: Icon(icon, color: colorScheme.primary),
        title: Text(title),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        onTap: () => _onStorageEntrySelected(entry),
      );
    }

    return [
      tile(
        entry: StorageBagEntry.snapshots,
        icon: Icons.backup_outlined,
        title: l10n.storage_entrySnapshots,
        subtitle: '',
      ),
      tile(
        entry: StorageBagEntry.import,
        icon: Icons.phonelink_ring_outlined,
        title: l10n.storage_importSection,
        subtitle: l10n.storage_importEntryHint,
      ),
      tile(
        entry: StorageBagEntry.advanced,
        icon: Icons.settings_suggest_outlined,
        title: l10n.storage_entryAdvanced,
        subtitle: l10n.storage_advancedEntryHint,
      ),
    ];
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
            _leftMode == _LeftPanelMode.conversations && !_isUtilityPanel
                ? activeColor
                : iconColor,
        onTap: _showConversations,
      ),
      _SidebarItemDef(
        icon: Icons.contacts_outlined,
        tooltip: l10n.drawer_contacts,
        colorBuilder: (_) =>
            _leftMode == _LeftPanelMode.contacts && !_isUtilityPanel
                ? activeColor
                : iconColor,
        onTap: _showContacts,
      ),
      _SidebarItemDef(
        icon: Icons.inventory_2_outlined,
        tooltip: l10n.storage_title,
        colorBuilder: (_) =>
            _leftMode == _LeftPanelMode.storage && !_isUtilityPanel
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
            _rightPanel == _RightPanelView.settings ? activeColor : iconColor,
        onTap: () => _showPanel(_RightPanelView.settings),
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
            return _SidebarIcon(
              icon: item.icon,
              tooltip: item.tooltip,
              color: item.colorBuilder(context),
              onTap: item.onTap,
            );
          }

          return Column(
            children: [
              const SizedBox(height: 12),
              Padding(
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

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    final IconData icon;
    final String label;
    switch (_leftMode) {
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
