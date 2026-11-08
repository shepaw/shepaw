import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/mobile_nav_bar.dart';
import '../widgets/mobile_shell_scope.dart';
import 'contacts_screen.dart';
import 'flow_workspace_screen.dart';
import 'home_screen.dart';
import 'jade_slip_screen.dart';
import 'mine_screen.dart';

/// Mobile root: five bottom-bar tabs (chats, jade slips, workflows, contacts,
/// me). Files and settings live inside the "me" tab. Inactive tabs stay mounted
/// after first open so list scroll position is kept.
///
/// Chat pages still push on the root navigator, which covers this shell so
/// the bar hides while in a conversation. The workflows, jade and me tabs each
/// have their own navigator: pages opened from them stay above the bar.
class MobileHomeShell extends StatefulWidget {
  const MobileHomeShell({super.key});

  /// 底栏条目顺序。tab 下标和文案只写一份；工作流排在玉简和通讯录中间。
  static List<MobileNavItem> navItems(AppLocalizations l10n) => [
        MobileNavItem(
          icon: Icons.chat_bubble_outline,
          selectedIcon: Icons.chat_bubble,
          label: l10n.nav_chats,
        ),
        MobileNavItem(
          icon: Icons.auto_stories_outlined,
          selectedIcon: Icons.auto_stories,
          label: l10n.jadeSlip_title,
        ),
        MobileNavItem(
          icon: Icons.account_tree_outlined,
          selectedIcon: Icons.account_tree,
          label: l10n.nav_flows,
        ),
        MobileNavItem(
          icon: Icons.people_outline,
          selectedIcon: Icons.people,
          label: l10n.contacts_title,
        ),
        MobileNavItem(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: l10n.nav_mine,
          showSettingsBadge: true,
        ),
      ];

  @override
  State<MobileHomeShell> createState() => _MobileHomeShellState();
}

class _MobileHomeShellState extends State<MobileHomeShell> {
  int _index = 0;
  final Set<int> _opened = {0};
  final GlobalKey<NavigatorState> _flowsNavKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _jadeNavKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _mineNavKey = GlobalKey<NavigatorState>();

  /// 工作流入口提出来，排在玉简和通讯录中间。
  static const int _jadeTab = 1;
  static const int _flowsTab = 2;
  static const int _contactsTab = 3;
  static const int _mineTab = 4;

  void _select(int index) {
    if (_index == index) return;
    setState(() {
      _index = index;
      _opened.add(index);
    });
  }

  Widget _tab(int i, Widget child) {
    if (!_opened.contains(i)) return const SizedBox.shrink();
    return Positioned.fill(
      child: TickerMode(
        enabled: _index == i,
        child: Offstage(
          offstage: _index != i,
          child: child,
        ),
      ),
    );
  }

  /// Pushes stay inside the tab so the bottom bar remains tappable.
  Widget _nestedTab({
    required int tab,
    required GlobalKey<NavigatorState> navKey,
    required WidgetBuilder root,
  }) {
    return NavigatorPopHandler<void>(
      enabled: _index == tab,
      onPopWithResult: (_) {
        navKey.currentState?.maybePop();
      },
      child: Navigator(
        key: navKey,
        onGenerateRoute: (settings) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: root,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reserve = MobileNavBar.occupiedHeight(context);

    return MobileShellScope(
      index: _index,
      onSelect: _select,
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(bottom: reserve),
                // The bar already covers the home indicator. Drop the bottom
                // inset so tab pages don't add a second empty band above it.
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: Stack(
                    children: [
                      _tab(0, const HomeScreen()),
                      _tab(
                        _jadeTab,
                        _nestedTab(
                          tab: _jadeTab,
                          navKey: _jadeNavKey,
                          root: (_) => const JadeSlipScreen(embedded: true),
                        ),
                      ),
                      _tab(
                        _flowsTab,
                        _nestedTab(
                          tab: _flowsTab,
                          navKey: _flowsNavKey,
                          root: (_) =>
                              const FlowWorkspaceScreen(embedded: true),
                        ),
                      ),
                      _tab(_contactsTab, const ContactsScreen()),
                      _tab(
                        _mineTab,
                        _nestedTab(
                          tab: _mineTab,
                          navKey: _mineNavKey,
                          root: (_) => const MineScreen(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MobileNavBar(
                index: _index,
                onSelect: _select,
                items: MobileHomeShell.navItems(l10n),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
