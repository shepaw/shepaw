import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// Tab content height above the home-indicator clearance.
  static const double height = 48;

  /// iOS home indicator is a thin mark near the edge. Padding the full
  /// safe-area inset (~34) leaves a tall empty band under the labels.
  static const double iosHomeIndicatorClearance = 15;

  /// Bottom padding under the icons.
  ///
  /// iOS and Android gesture navigation only need to clear a thin
  /// indicator. Android 3-button navigation keeps the full inset so the
  /// icons stay above the system buttons.
  static double contentBottomInset(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).bottom;
    if (safe <= 0) return 0;
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS) {
      return safe > iosHomeIndicatorClearance
          ? iosHomeIndicatorClearance
          : safe;
    }
    if (platform == TargetPlatform.android) {
      final gesture = MediaQuery.systemGestureInsetsOf(context).bottom;
      final threeButton = safe >= 40 && gesture < 8;
      if (!threeButton && safe > iosHomeIndicatorClearance) {
        return iosHomeIndicatorClearance;
      }
    }
    return safe;
  }

  /// Total height occupied by the bar, including the bottom clearance.
  static double occupiedHeight(BuildContext context) =>
      height + contentBottomInset(context);

  final int index;
  final List<MobileNavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bottomInset = contentBottomInset(context);

    final barColor = scheme.surface;
    const selectedFg = AppColors.primary;
    final unselectedFg = scheme.onSurfaceVariant;
    final dividerColor =
        isDark ? scheme.outline.withValues(alpha: 0.7) : scheme.outline;

    // Sampled at the system navigation bar so Android paints that strip
    // the same color as this bar instead of the page background.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: barColor,
        systemNavigationBarDividerColor: barColor,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Material(
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
