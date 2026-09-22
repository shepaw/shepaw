import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'update_settings_badge.dart';

/// WeChat-style bottom tab bar: full width, flush with the screen edge.
/// The selected tab's icon and label use the brand orange; unselected
/// tabs stay muted. The bar background extends through the home-indicator
/// inset.
class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.index,
    required this.items,
    required this.onSelect,
  });

  /// Tab content height above the system safe area.
  static const double height = 48;

  /// Space to keep above the home indicator so content is not covered.
  static const double reserveAboveSafeArea = height;

  final int index;
  final List<MobileNavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    final barColor = scheme.surface;
    final selectedFg = AppColors.primary;
    final unselectedFg = scheme.onSurfaceVariant;
    final dividerColor = isDark
        ? scheme.outline.withValues(alpha: 0.7)
        : scheme.outline;

    return Material(
      color: barColor,
      child: Ink(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavDestination(
                      item: items[i],
                      selected: i == index,
                      selectedFg: selectedFg,
                      unselectedFg: unselectedFg,
                      onTap: () => onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MobileNavItem {
  const MobileNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.showSettingsBadge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool showSettingsBadge;
}

class _NavDestination extends StatelessWidget {
  const _NavDestination({
    required this.item,
    required this.selected,
    required this.selectedFg,
    required this.unselectedFg,
    required this.onTap,
  });

  final MobileNavItem item;
  final bool selected;
  final Color selectedFg;
  final Color unselectedFg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? selectedFg : unselectedFg;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _icon(fg),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: FontWeight.w400,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(Color fg) {
    final icon = Icon(
      selected ? item.selectedIcon : item.icon,
      size: 22,
      color: fg,
    );
    if (!item.showSettingsBadge) return icon;
    return SettingsUpdateBadge(child: icon);
  }
}
