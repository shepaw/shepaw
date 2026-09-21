import 'package:flutter/widgets.dart';

/// Marks widgets that live in the mobile bottom-bar shell so tab-root screens
/// can hide a back button without threading a flag through every route.
class MobileShellScope extends InheritedWidget {
  const MobileShellScope({
    super.key,
    required this.index,
    required this.onSelect,
    required super.child,
  });

  final int index;
  final ValueChanged<int> onSelect;

  static MobileShellScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MobileShellScope>();
  }

  static bool isActive(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(MobileShellScope oldWidget) {
    return index != oldWidget.index || onSelect != oldWidget.onSelect;
  }
}
