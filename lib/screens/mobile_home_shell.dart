import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/update_service.dart';
import '../widgets/mobile_nav_bar.dart';
import '../widgets/mobile_shell_scope.dart';
import 'contacts_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'storage_space_manage_screen.dart';

/// Mobile root: four bottom-bar tabs. Inactive tabs stay mounted after first
/// open so list scroll position is kept.
///
/// Chat / detail pages still push on the root navigator, which covers this
/// shell so the bar hides while in a conversation.
class MobileHomeShell extends StatefulWidget {
  const MobileHomeShell({super.key});

  @override
  State<MobileHomeShell> createState() => _MobileHomeShellState();
}

class _MobileHomeShellState extends State<MobileHomeShell> {
  int _index = 0;
  final Set<int> _opened = {0};

  void _select(int index) {
    if (index == 3) {
      UpdateService().dismissSettingsIconBadge();
    }
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final reserve = MobileNavBar.reserveAboveSafeArea + bottomInset;

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
                child: Stack(
                  children: [
                    _tab(0, const HomeScreen()),
                    _tab(1, const ContactsScreen()),
                    _tab(2, const StorageSpaceManageScreen()),
                    _tab(3, const SettingsScreen()),
                  ],
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
                items: [
                  MobileNavItem(
                    icon: Icons.chat_bubble_outline,
                    selectedIcon: Icons.chat_bubble,
                    label: l10n.nav_chats,
                  ),
                  MobileNavItem(
                    icon: Icons.people_outline,
                    selectedIcon: Icons.people,
                    label: l10n.contacts_title,
                  ),
                  MobileNavItem(
                    icon: Icons.inventory_2_outlined,
                    selectedIcon: Icons.inventory_2,
                    label: l10n.nav_storage,
                  ),
                  MobileNavItem(
                    icon: Icons.settings_outlined,
                    selectedIcon: Icons.settings,
                    label: l10n.nav_settings,
                    showSettingsBadge: true,
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
