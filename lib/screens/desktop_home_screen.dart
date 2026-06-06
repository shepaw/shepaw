import 'dart:async';
import 'package:flutter/material.dart';
import '../models/conversation_selection.dart';
import '../l10n/app_localizations.dart';
import '../widgets/model_icon.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_chat_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'channel_trace_screen.dart';
import 'group_workflow_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'skill_management_screen.dart';
import 'model_management_screen.dart';
import 'cli_config_management_screen.dart';
import '../task/screens/scheduled_tasks_management_screen.dart';
import '../task/screens/scheduled_task_form_screen.dart';
import '../task/models/scheduled_task.dart';
import '../utils/layout_utils.dart';
import '../services/native_window_service.dart';

/// Desktop split-panel layout similar to WeChat desktop.
/// Left: icon sidebar + conversation list (HomeScreen embedded).
/// Right: chat view (ChatScreen embedded) or empty state.
class DesktopHomeScreen extends StatefulWidget {
  const DesktopHomeScreen({Key? key}) : super(key: key);

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

/// Tracks what the right panel is currently displaying.
enum _RightPanelView {
  empty,
  chat,
  settings,
  addAgent,
  createGroup,
  pairDevice,
  contacts,
  traces,
  groupWorkflow,
  modelManagement,
  skillManagement,
  toolConfigManagement,
  scheduledTaskManagement,
  createScheduledTask,
  editScheduledTask,
}

/// Describes one item in the icon sidebar.
class _SidebarItemDef {
  final IconData icon;
  final String tooltip;
  final Color Function(BuildContext) colorBuilder;
  final VoidCallback onTap;

  /// Optional custom glyph (e.g. an SVG-based icon) rendered instead of [icon].
  final Widget Function(double size, Color color)? iconBuilder;

  const _SidebarItemDef({
    required this.icon,
    required this.tooltip,
    required this.colorBuilder,
    this.iconBuilder,
    required this.onTap,
  });
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  final OverlayPortalController _morePortalController = OverlayPortalController();
  StreamSubscription? _peerEventSub;
  StreamSubscription? _peerListChangedSub;

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _peerEventSub?.cancel();
    _peerListChangedSub?.cancel();
    FloatingPanelManager.instance.closeAll();
    NativeWindowService.instance.closeAll();
    super.dispose();
  }

  ConversationSelection? _selected;
  double _leftPanelWidth = 320;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  _RightPanelView _rightPanel = _RightPanelView.empty;

  /// The task being edited in the editScheduledTask panel.
  ScheduledTask? _editingTask;

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

  void _onConversationSelected(ConversationSelection selection) {
    setState(() {
      _previousPanel = null;
      _selected = selection;
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

  void _onSwitchChannel(String channelId) {
    if (_selected == null) return;
    setState(() {
      _selected = ConversationSelection(
        agentId: _selected!.agentId,
        agentName: _selected!.agentName,
        agentAvatar: _selected!.agentAvatar,
        channelId: channelId,
        groupFamilyId: _selected!.groupFamilyId,
      );
      _navGeneration++;
    });
  }

  void _reloadAgents() {
    _homeKey.currentState?.reloadAgents();
  }

  void _showPanel(_RightPanelView panel) {
    if (_rightPanel == panel) return; // already showing this panel
    setState(() {
      _rightPanel = panel;
      if (panel != _RightPanelView.chat) {
        _selected = null;
      }
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

          // Conversation list panel
          SizedBox(
            width: _leftPanelWidth,
            child: HomeScreen(
              key: _homeKey,
              embedded: true,
              selectedConversation: _selected,
              onConversationSelected: _onConversationSelected,
              onAddAgent: () => _showPanel(_RightPanelView.addAgent),
              onCreateGroup: () => _showPanel(_RightPanelView.createGroup),
              onPairDevice: () => _showPanel(_RightPanelView.pairDevice),
            ),
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
            _showPanel(_RightPanelView.empty);
          },
        );

      case _RightPanelView.createGroup:
        return CreateGroupScreen(
          onGroupCreated: (channelId) {
            _reloadAgents();
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
            // 配对成功后直接打开与该设备的聊天。
            _onConversationSelected(ConversationSelection(peerId: peer.id));
          },
        );

      case _RightPanelView.contacts:
        return const ContactsScreen();

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

      case _RightPanelView.modelManagement:
        return const ModelManagementScreen();

      case _RightPanelView.skillManagement:
        return const SkillManagementScreen();

      case _RightPanelView.toolConfigManagement:
        return const CliConfigManagementScreen();

      case _RightPanelView.scheduledTaskManagement:
        return ScheduledTasksManagementScreen(
          onCreateTask: () {
            setState(() {
              _editingTask = null;
              _rightPanel = _RightPanelView.createScheduledTask;
              _navGeneration++;
            });
          },
          onEditTask: (task) {
            setState(() {
              _editingTask = task;
              _rightPanel = _RightPanelView.editScheduledTask;
              _navGeneration++;
            });
          },
        );

      case _RightPanelView.createScheduledTask:
        return ScheduledTaskFormScreen(
          onDone: () {
            _showPanel(_RightPanelView.scheduledTaskManagement);
          },
        );

      case _RightPanelView.editScheduledTask:
        return ScheduledTaskFormScreen(
          task: _editingTask,
          onDone: () {
            _showPanel(_RightPanelView.scheduledTaskManagement);
          },
        );

      case _RightPanelView.empty:
        return _buildEmptyState();
    }
  }

  /// WeChat-style narrow icon sidebar on the far left.
  Widget _buildSidebar() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sidebarBg = colorScheme.surfaceContainerHighest;
    final iconColor = colorScheme.onSurfaceVariant;
    final activeColor = colorScheme.primary;

    // Top section items (always visible, never collapsed)
    final topItems = [
      _SidebarItemDef(
        icon: Icons.chat_bubble,
        tooltip: l10n.drawer_myProfile,
        colorBuilder: (_) => _rightPanel == _RightPanelView.chat ||
                _rightPanel == _RightPanelView.empty
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.empty),
      ),
      _SidebarItemDef(
        icon: Icons.contacts_outlined,
        tooltip: l10n.drawer_contacts,
        colorBuilder: (_) =>
            _rightPanel == _RightPanelView.contacts ? activeColor : iconColor,
        onTap: () => _showPanel(_RightPanelView.contacts),
      ),
    ];

    // Bottom section items (collapsed when height is insufficient)
    // Index 0–4: before divider; after that: settings
    final bottomItems = [
      _SidebarItemDef(
        icon: Icons.psychology,
        iconBuilder: (size, color) => ModelIcon(size: size, color: color),
        tooltip: l10n.toolModel_managementTitle,
        colorBuilder: (_) => _rightPanel == _RightPanelView.modelManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.modelManagement),
      ),
      _SidebarItemDef(
        icon: Icons.auto_awesome_outlined,
        tooltip: l10n.skillMgmt_title,
        colorBuilder: (_) => _rightPanel == _RightPanelView.skillManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.skillManagement),
      ),
      _SidebarItemDef(
        icon: Icons.terminal,
        tooltip: 'CLI Commands',
        colorBuilder: (_) => _rightPanel == _RightPanelView.toolConfigManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.toolConfigManagement),
      ),
      _SidebarItemDef(
        icon: Icons.schedule,
        tooltip: l10n.scheduledTasks_title,
        colorBuilder: (_) => _rightPanel == _RightPanelView.scheduledTaskManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.scheduledTaskManagement),
      ),
      // divider placeholder – index 5
      _SidebarItemDef(
        icon: Icons.horizontal_rule, // sentinel, won't render directly
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
    const dividerIndex = 5; // index in bottomItems that is the divider sentinel

    return Container(
      width: _sidebarWidth,
      color: sidebarBg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableHeight = constraints.maxHeight;

          // Fixed height constants
          const double topPadding = 12.0;
          const double logoHeight = 52.0; // 8+36+8
          const double itemHeight = 42.0; // 10+22+10
          const double dividerHeight = 17.0; // Divider height: 1 + 16 padding
          const double bottomPadding = 12.0;
          const double moreItemHeight = itemHeight; // same as a regular item

          // Fixed overhead: top padding + logo + spacer is flexible
          // We just need to figure out total of non-spacer items
          final double topItemsHeight = topItems.length * itemHeight;

          // Calculate bottom section natural height
          double bottomNaturalHeight = 0;
          for (int i = 0; i < bottomItems.length; i++) {
            if (i == dividerIndex) {
              bottomNaturalHeight += dividerHeight;
            } else {
              bottomNaturalHeight += itemHeight;
            }
          }

          // How much space is available for bottom items
          // (spacer can shrink to 0 if needed)
          final double spaceForBottom =
              availableHeight - topPadding - logoHeight - topItemsHeight - bottomPadding;

          // Determine which bottom items to show vs overflow
          List<_SidebarItemDef> visibleBottom = [];
          List<_SidebarItemDef> overflowItems = [];
          bool needsMoreButton = false;

          if (spaceForBottom >= bottomNaturalHeight) {
            // Enough space for everything
            visibleBottom = List.from(bottomItems);
          } else {
            // Need to figure out what fits.
            // Strategy: pack from the end (settings+logout must show if possible),
            // then fill remaining from the start.
            // Actually simpler: remove items from the MIDDLE (index 0 upward)
            // keeping settings+logout always visible at the bottom.
            // But per user request: overflow goes from top of bottom section.
            needsMoreButton = true;

            // Minimum bottom section: just the "more" button + divider + settings
            // = moreItemHeight + dividerHeight + itemHeight
            const double minBottomHeight =
                moreItemHeight + dividerHeight + itemHeight;

            // Available height for bottom section (allow spacer to compress to 0)
            final double usableForBottom =
                (spaceForBottom).clamp(minBottomHeight, double.infinity);

            // Items to always keep: divider + settings (indices 7,8)
            const alwaysKeep = [7, 8]; // divider, settings
            double alwaysHeight = dividerHeight + itemHeight;

            // Remaining budget for collapsible items (indices 0-6) + more button
            double budget = usableForBottom - alwaysHeight - moreItemHeight;

            // Pack collapsible items from end to beginning (last ones have priority)
            final collapsibleIndices = [6, 5, 4, 3, 2, 1, 0];
            List<int> shownCollapsible = [];
            for (final idx in collapsibleIndices) {
              if (budget >= itemHeight) {
                shownCollapsible.insert(0, idx);
                budget -= itemHeight;
              }
            }

            final shownSet = {...shownCollapsible, ...alwaysKeep};
            for (int i = 0; i < bottomItems.length; i++) {
              if (shownSet.contains(i)) {
                visibleBottom.add(bottomItems[i]);
              } else {
                if (i != dividerIndex) {
                  overflowItems.add(bottomItems[i]);
                }
              }
            }
          }

          // Build bottom section widgets
          Widget buildItem(_SidebarItemDef item, BuildContext ctx) {
            return _SidebarIcon(
              icon: item.icon,
              tooltip: item.tooltip,
              color: item.colorBuilder(ctx),
              onTap: item.onTap,
              iconBuilder: item.iconBuilder,
            );
          }

          final List<Widget> bottomWidgets = [];
          bool dividerInserted = false;
          bool moreInserted = false;

          for (int i = 0; i < visibleBottom.length; i++) {
            final item = visibleBottom[i];

            // Insert "more" button before the divider (before always-keep section)
            if (!moreInserted && needsMoreButton) {
              // Check if this is the divider sentinel or the first always-keep item
              final originalIndex = bottomItems.indexOf(item);
              if (originalIndex >= dividerIndex && !dividerInserted) {
                // Insert "more" button here
                bottomWidgets.add(_buildMoreButton(overflowItems, colorScheme));
                moreInserted = true;
              }
            }

            if (item.icon == Icons.horizontal_rule) {
              // Render divider
              bottomWidgets
                  .add(const Divider(indent: 12, endIndent: 12, height: 17));
              dividerInserted = true;
            } else {
              bottomWidgets.add(buildItem(item, context));
            }
          }

          // If more button wasn't inserted yet (edge case)
          if (needsMoreButton && !moreInserted) {
            bottomWidgets.insert(0, _buildMoreButton(overflowItems, colorScheme));
          }

          // Spacer height (can be 0 if not enough space)
          final double spacerHeight = (availableHeight -
                  topPadding -
                  logoHeight -
                  topItemsHeight -
                  bottomPadding -
                  visibleBottom.fold<double>(0.0, (sum, item) {
                    if (item.icon == Icons.horizontal_rule) return sum + dividerHeight;
                    return sum + itemHeight;
                  }) -
                  (needsMoreButton ? moreItemHeight : 0))
              .clamp(0.0, double.infinity);

          return Column(
            children: [
              const SizedBox(height: 12),
              // App avatar / brand
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
              // Top items
              ...topItems.map((item) => _SidebarIcon(
                    icon: item.icon,
                    tooltip: item.tooltip,
                    color: item.colorBuilder(context),
                    onTap: item.onTap,
                    iconBuilder: item.iconBuilder,
                  )),
              // Flexible spacer
              SizedBox(height: spacerHeight),
              // Bottom items
              ...bottomWidgets,
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }

  /// Builds the "more (···)" button with an OverlayPortal popup.
  Widget _buildMoreButton(
    List<_SidebarItemDef> overflowItems,
    ColorScheme colorScheme,
  ) {
    // Use a Builder so we can capture the button's own BuildContext
    // for accurate RenderBox position lookup inside overlayChildBuilder.
    return Builder(
      builder: (buttonCtx) {
        return OverlayPortal(
          controller: _morePortalController,
          overlayChildBuilder: (ctx) {
            // Obtain the position of the "more" button in global coordinates
            final renderBox =
                buttonCtx.findRenderObject() as RenderBox?;
            Offset buttonOffset = Offset.zero;
            if (renderBox != null && renderBox.hasSize) {
              buttonOffset = renderBox.localToGlobal(Offset.zero);
            }
            return Stack(
              children: [
                // Barrier to close on outside tap
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      _morePortalController.hide();
                      setState(() {});
                    },
                  ),
                ),
                // Popup panel: right of sidebar, vertically aligned to button
                Positioned(
                  left: _sidebarWidth,
                  top: buttonOffset.dy,
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    color: colorScheme.surfaceContainerHighest,
                    child: SizedBox(
                      width: _sidebarWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: overflowItems.map((item) {
                            return _SidebarIcon(
                              icon: item.icon,
                              tooltip: item.tooltip,
                              color: item.colorBuilder(ctx),
                              iconBuilder: item.iconBuilder,
                              onTap: () {
                                _morePortalController.hide();
                                setState(() {});
                                item.onTap();
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          child: _SidebarIcon(
            icon: Icons.more_horiz,
            tooltip: '更多',
            color: colorScheme.onSurfaceVariant,
            onTap: () {
              if (_morePortalController.isShowing) {
                _morePortalController.hide();
              } else {
                _morePortalController.show();
              }
              setState(() {});
            },
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            l10n.home_noMessages,
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


/// A single icon button in the sidebar.
class _SidebarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  final Widget Function(double size, Color color)? iconBuilder;

  const _SidebarIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.iconBuilder,
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
          child: iconBuilder != null
              ? iconBuilder!(22, color)
              : Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }
}
