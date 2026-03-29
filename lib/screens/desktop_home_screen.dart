import 'package:flutter/material.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../models/conversation_selection.dart';
import '../l10n/app_localizations.dart';
import '../services/local_database_service.dart';
import '../services/message_search_service.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'channel_trace_screen.dart';
import 'add_remote_agent_screen.dart';
import 'create_group_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'skill_management_screen.dart';
import 'model_management_screen.dart';
import 'tool_config_management_screen.dart';
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
  contacts,
  search,
  traces,
  modelManagement,
  skillManagement,
  toolConfigManagement,
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
  final OverlayPortalController _morePortalController = OverlayPortalController();

  @override
  void dispose() {
    FloatingPanelManager.instance.closeAll();
    NativeWindowService.instance.closeAll();
    super.dispose();
  }

  ConversationSelection? _selected;
  double _leftPanelWidth = 320;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  _RightPanelView _rightPanel = _RightPanelView.empty;

  /// The actual channelId of the chat that triggered the traces view.
  /// May differ from _selected?.channelId when the controller created/loaded
  /// a channel after the initial ConversationSelection was recorded.
  String? _tracesChannelId;

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

  /// Called when a conversation is opened from the search panel.
  /// Remembers search as the previous panel so the back button returns to it.
  void _onSearchConversationSelected(ConversationSelection selection) {
    setState(() {
      _previousPanel = _RightPanelView.search;
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

      case _RightPanelView.contacts:
        return const ContactsScreen();

      case _RightPanelView.search:
        return _DesktopSearchPanel(
          agents: _homeKey.currentState?.agents ?? [],
          onConversationSelected: _onSearchConversationSelected,
        );

      case _RightPanelView.traces:
        return ChannelTraceScreen(
          channelId: _tracesChannelId,
          channelName: _selected?.agentName,
          onBack: _onTracesBack,
        );

      case _RightPanelView.modelManagement:
        return const ModelManagementScreen();

      case _RightPanelView.skillManagement:
        return const SkillManagementScreen();

      case _RightPanelView.toolConfigManagement:
        return const ToolConfigManagementScreen();

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
        icon: Icons.search,
        tooltip: l10n.common_search,
        colorBuilder: (_) =>
            _rightPanel == _RightPanelView.search ? activeColor : iconColor,
        onTap: () => _openSearch(),
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
    // Index 0–3: before divider; after that: settings + logout
    final bottomItems = [
      _SidebarItemDef(
        icon: Icons.person_add_outlined,
        tooltip: l10n.drawer_newAgent,
        colorBuilder: (_) =>
            _rightPanel == _RightPanelView.addAgent ? activeColor : iconColor,
        onTap: () => _showPanel(_RightPanelView.addAgent),
      ),
      _SidebarItemDef(
        icon: Icons.group_add_outlined,
        tooltip: l10n.drawer_newGroup,
        colorBuilder: (_) =>
            _rightPanel == _RightPanelView.createGroup ? activeColor : iconColor,
        onTap: () => _showPanel(_RightPanelView.createGroup),
      ),
      _SidebarItemDef(
        icon: Icons.hub,
        tooltip: l10n.toolModel_managementTitle,
        colorBuilder: (_) => _rightPanel == _RightPanelView.modelManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.modelManagement),
      ),
      _SidebarItemDef(
        icon: Icons.auto_stories,
        tooltip: l10n.settings_skillDirectory,
        colorBuilder: (_) => _rightPanel == _RightPanelView.skillManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.skillManagement),
      ),
      _SidebarItemDef(
        icon: Icons.build_circle,
        tooltip: l10n.osTool_configTitle,
        colorBuilder: (_) => _rightPanel == _RightPanelView.toolConfigManagement
            ? activeColor
            : iconColor,
        onTap: () => _showPanel(_RightPanelView.toolConfigManagement),
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
      _SidebarItemDef(
        icon: Icons.logout,
        tooltip: l10n.drawer_logout,
        colorBuilder: (_) => Colors.red,
        onTap: _showLogoutDialog,
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

            // Minimum bottom section: just the "more" button + divider + settings + logout
            // = moreItemHeight + dividerHeight + itemHeight*2
            const double minBottomHeight =
                moreItemHeight + dividerHeight + itemHeight * 2;

            // Available height for bottom section (allow spacer to compress to 0)
            final double usableForBottom =
                (spaceForBottom).clamp(minBottomHeight, double.infinity);

            // Items to always keep: divider + settings + logout (indices 4,5,6)
            const alwaysKeep = [4, 5, 6]; // divider, settings, logout
            double alwaysHeight = dividerHeight + itemHeight * 2;

            // Remaining budget for collapsible items (indices 0-3) + more button
            double budget = usableForBottom - alwaysHeight - moreItemHeight;

            // Pack collapsible items from end to beginning (last ones have priority)
            final collapsibleIndices = [3, 2, 1, 0];
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

  void _openSearch() {
    _showPanel(_RightPanelView.search);
  }

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
              Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil(
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

/// Inline search panel displayed in the right panel on desktop.
class _DesktopSearchPanel extends StatefulWidget {
  final List<Agent> agents;
  final ValueChanged<ConversationSelection> onConversationSelected;

  const _DesktopSearchPanel({
    required this.agents,
    required this.onConversationSelected,
  });

  @override
  State<_DesktopSearchPanel> createState() => _DesktopSearchPanelState();
}

class _DesktopSearchPanelState extends State<_DesktopSearchPanel> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  late final MessageSearchService _messageSearchService;

  List<Agent> _agentResults = [];
  List<Channel> _channelResults = [];
  List<MessageSearchResult> _messageResults = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _messageSearchService = MessageSearchService(_databaseService);
    _controller.addListener(_onQueryChanged);
    // Auto-focus the search field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _agentResults = [];
        _channelResults = [];
        _messageResults = [];
        _searching = false;
      });
      return;
    }
    _performSearch(query);
  }

  Future<void> _performSearch(String query) async {
    setState(() => _searching = true);

    final lowerQuery = query.toLowerCase();
    final agentResults = widget.agents.where((a) {
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

    if (!mounted || _controller.text.trim() != query) return;
    setState(() {
      _agentResults = agentResults;
      _channelResults = channelResults;
      _messageResults = messageResults;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            hintText: l10n.common_search,
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => _controller.clear(),
                  )
                : null,
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Search agents, groups, and messages',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    if (_searching &&
        _agentResults.isEmpty &&
        _channelResults.isEmpty &&
        _messageResults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasAgents = _agentResults.isNotEmpty;
    final hasChannels = _channelResults.isNotEmpty;
    final hasMessages = _messageResults.isNotEmpty;

    if (!hasAgents && !hasChannels && !hasMessages) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        if (hasAgents) ...[
          _buildSectionHeader(context, 'Agents', _agentResults.length),
          ..._agentResults.map((agent) => _buildAgentTile(context, agent)),
        ],
        if (hasChannels) ...[
          _buildSectionHeader(context, 'Groups', _channelResults.length),
          ..._channelResults.map((ch) => _buildChannelTile(context, ch)),
        ],
        if (hasMessages) ...[
          _buildSectionHeader(context, 'Messages', _messageResults.length),
          ..._messageResults.map((r) => _buildMessageTile(context, r)),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.grey[50],
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[700])),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentTile(BuildContext context, Agent agent) {
    return ListTile(
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
            : ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  agent.avatar,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Text(
                    agent.name.isNotEmpty ? agent.name[0] : 'A',
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
              ),
      ),
      title: Text(agent.name),
      subtitle: Text(agent.description ?? agent.type ?? 'AI Agent'),
      onTap: () {
        widget.onConversationSelected(ConversationSelection(
          agentId: agent.id,
          agentName: agent.name,
          agentAvatar: agent.avatar,
        ));
      },
    );
  }

  Widget _buildChannelTile(BuildContext context, Channel channel) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.blue[50],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(
          channel.isGroup ? Icons.group : Icons.chat_bubble_outline,
          color: Colors.blue[700],
          size: 20,
        ),
      ),
      title: Text(channel.name),
      subtitle:
          Text(channel.description ?? (channel.isGroup ? 'Group' : 'Chat')),
      onTap: () {
        widget.onConversationSelected(ConversationSelection(
          channelId: channel.id,
          groupFamilyId: channel.isGroup ? channel.groupFamilyId : null,
        ));
      },
    );
  }

  Widget _buildMessageTile(BuildContext context, MessageSearchResult result) {
    final message = result.message;
    final isMyMessage = message.from.type == 'user';
    return InkWell(
      onTap: () {
        widget.onConversationSelected(ConversationSelection(
          channelId: message.channelId,
          highlightMessageId: message.id,
        ));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    result.channelName.isNotEmpty
                        ? result.channelName
                        : 'Unknown',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isMyMessage
                        ? Theme.of(context).primaryColor.withOpacity(0.15)
                        : Colors.grey[200],
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    message.senderName.isNotEmpty
                        ? message.senderName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: isMyMessage
                          ? Theme.of(context).primaryColor
                          : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: isMyMessage
                        ? Theme.of(context).primaryColor
                        : Colors.grey[800],
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTime(message.timestampMs),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _buildHighlightedContent(context, message.content),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedContent(BuildContext context, String content) {
    final query = _controller.text.trim();
    final baseStyle = TextStyle(color: Colors.grey[800], fontSize: 13);
    if (query.isEmpty) {
      return Text(content,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: baseStyle);
    }

    // Collapse all whitespace (newlines, tabs, etc.) into single spaces so
    // the match is always visible in the snippet.
    final flat = content.replaceAll(RegExp(r'\s+'), ' ');
    final lowerFlat = flat.toLowerCase();
    final lowerQuery = query.toLowerCase();

    final matchIndex = lowerFlat.indexOf(lowerQuery);
    if (matchIndex == -1) {
      return Text(flat,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: baseStyle);
    }

    // Extract a window of ~40 chars before and after the first match.
    const windowSize = 40;
    final snippetStart = matchIndex > windowSize ? matchIndex - windowSize : 0;
    final matchEnd = matchIndex + query.length;
    final snippetEnd =
        (matchEnd + windowSize).clamp(0, flat.length);

    final before = flat.substring(snippetStart, matchIndex);
    final match = flat.substring(matchIndex, matchEnd);
    final after = flat.substring(matchEnd, snippetEnd);

    final spans = <TextSpan>[
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
    ];

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[dt.weekday - 1];
    } else {
      return '${dt.month}/${dt.day}';
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
