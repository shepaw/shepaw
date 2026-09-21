import 'package:flutter/material.dart';

import 'update_settings_badge.dart';

/// Floating capsule bottom bar, matching the phone-app screenshot:
/// selected tab is a filled pill; unselected tabs stay muted.
class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.index,
    required this.items,
    required this.onSelect,
  });

  static const double height = 64;
  static const double horizontalMargin = 16;
  static const double bottomGap = 8;

  /// Space to keep above the home indicator so content is not covered.
  static const double reserveAboveSafeArea = height + bottomGap;

  final int index;
  final List<MobileNavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final barColor = isDark
        ? const Color(0xFF2A2C32)
        : scheme.surface;
    final selectedBg = isDark ? Colors.white : scheme.onSurface;
    final selectedFg = isDark ? const Color(0xFF1A1C20) : scheme.surface;
    final unselectedFg = scheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(28),
          border: isDark
              ? null
              : Border.all(color: scheme.outline.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _NavDestination(
                  item: items[i],
                  selected: i == index,
                  selectedBg: selectedBg,
                  selectedFg: selectedFg,
                  unselectedFg: unselectedFg,
                  onTap: () => onSelect(i),
                ),
              ),
          ],
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
    required this.selectedBg,
    required this.selectedFg,
    required this.unselectedFg,
    required this.onTap,
  });

  final MobileNavItem item;
  final bool selected;
  final Color selectedBg;
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
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
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
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
