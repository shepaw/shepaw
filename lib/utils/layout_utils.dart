import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/locale_provider.dart';
import '../services/native_window_service.dart';

class LayoutUtils {
  LayoutUtils._();

  /// Returns true when running on a desktop OS (macOS/Windows/Linux)
  /// with a window width >= 600 logical pixels.
  static bool isDesktopLayout(BuildContext context) {
    if (kIsWeb) return false;
    final isDesktopOS = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (!isDesktopOS) return false;
    return MediaQuery.of(context).size.width >= 600;
  }

  /// Shows a right-side drawer panel on desktop, or a modal bottom sheet on mobile.
  /// [builder] receives a BuildContext and should return the panel content widget.
  /// Returns a Future that completes with the value passed to Navigator.pop().
  static Future<T?> showAdaptivePanel<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = false,
    ShapeBorder? shape,
  }) {
    if (isDesktopLayout(context)) {
      return showRightDrawer<T>(context: context, builder: builder);
    } else {
      return showModalBottomSheet<T>(
        context: context,
        isScrollControlled: isScrollControlled,
        shape: shape,
        builder: builder,
      );
    }
  }

  /// Shows a panel that slides in from the right side of the screen.
  /// Fixed width of 360px with a slide animation from right to left.
  static Future<T?> showRightDrawer<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            elevation: 16,
            child: SizedBox(
              width: 360,
              height: MediaQuery.of(context).size.height,
              child: SafeArea(
                child: builder(context),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final offsetAnimation = Tween<Offset>(
          begin: const Offset(1.0, 0.0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ));
        return SlideTransition(
          position: offsetAnimation,
          child: child,
        );
      },
    );
  }

  /// Opens a floating panel on desktop, or a full-screen route on mobile.
  ///
  /// On desktop with native multi-window support, the content is opened in a
  /// true OS-native window that can be dragged outside the main app window.
  /// Falls back to in-app overlay panels if native windows are unavailable.
  /// On mobile, it falls back to a normal [MaterialPageRoute].
  static void openFloatingPanel({
    required BuildContext context,
    required String key,
    required String title,
    required WidgetBuilder builder,
  }) {
    if (isDesktopLayout(context)) {
      if (NativeWindowService.isSupported) {
        // Read current locale from provider to pass to sub-window.
        final localeProvider =
            Provider.of<LocaleProvider>(context, listen: false);
        final localeCode = localeProvider.locale?.languageCode ??
            Localizations.maybeLocaleOf(context)?.languageCode;
        NativeWindowService.instance.openPanel(
          key: key,
          title: title,
          locale: localeCode,
        );
      } else {
        FloatingPanelManager.instance.open(
          context: context,
          key: key,
          title: title,
          builder: builder,
        );
      }
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: builder),
      );
    }
  }
}

// =============================================================================
// Floating Panel Manager
// =============================================================================

/// Manages floating overlay panels. Singleton.
class FloatingPanelManager {
  FloatingPanelManager._();
  static final FloatingPanelManager instance = FloatingPanelManager._();

  final Map<String, OverlayEntry> _panels = {};
  final Map<String, VoidCallback> _removers = {};
  OverlayState? _overlayState;

  /// The set of open panel keys (for cascade offset calculation).
  int get openCount => _panels.length;

  /// Opens a floating panel. If a panel with the same [key] is already open,
  /// brings it to front instead of creating a duplicate.
  void open({
    required BuildContext context,
    required String key,
    required String title,
    required WidgetBuilder builder,
  }) {
    if (_panels.containsKey(key)) {
      bringToFront(key);
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);
    _overlayState = overlay;
    final screenSize = MediaQuery.of(context).size;

    // Calculate cascade offset: center-right with 30px offset per open panel.
    final cascadeOffset = openCount * 30.0;
    final initialLeft =
        (screenSize.width - 480) / 2 + 60 + cascadeOffset;
    final initialTop =
        (screenSize.height - 600) / 2 + cascadeOffset;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _FloatingPanelWidget(
        title: title,
        initialLeft: initialLeft.clamp(40, screenSize.width - 400),
        initialTop: initialTop.clamp(40, screenSize.height - 440),
        onClose: () => close(key),
        onTap: () => bringToFront(key),
        contentBuilder: builder,
      ),
    );

    _panels[key] = entry;
    overlay.insert(entry);
  }

  /// Closes and removes the panel with the given [key].
  void close(String key) {
    final entry = _panels.remove(key);
    entry?.remove();
    _removers.remove(key);
  }

  /// Closes all open panels.
  void closeAll() {
    for (final entry in _panels.values) {
      entry.remove();
    }
    _panels.clear();
    _removers.clear();
  }

  /// Brings the panel with [key] to the front by re-inserting it.
  void bringToFront(String key) {
    final entry = _panels[key];
    if (entry == null) return;

    final overlay = _overlayState;
    if (overlay == null || !overlay.mounted) return;

    entry.remove();
    final newEntry = OverlayEntry(builder: entry.builder);
    _panels[key] = newEntry;
    overlay.insert(newEntry);
  }

}

// =============================================================================
// Floating Panel Widget
// =============================================================================

class _FloatingPanelWidget extends StatefulWidget {
  final String title;
  final double initialLeft;
  final double initialTop;
  final VoidCallback onClose;
  final VoidCallback onTap;
  final WidgetBuilder contentBuilder;

  const _FloatingPanelWidget({
    required this.title,
    required this.initialLeft,
    required this.initialTop,
    required this.onClose,
    required this.onTap,
    required this.contentBuilder,
  });

  @override
  State<_FloatingPanelWidget> createState() => _FloatingPanelWidgetState();
}

class _FloatingPanelWidgetState extends State<_FloatingPanelWidget> {
  late double _left;
  late double _top;
  double _width = 480;
  double _height = 600;

  static const double _minWidth = 360;
  static const double _minHeight = 400;
  static const double _titleBarHeight = 40;

  @override
  void initState() {
    super.initState();
    _left = widget.initialLeft;
    _top = widget.initialTop;
  }

  void _clampPosition(Size screenSize) {
    // Allow the panel to move mostly off-screen, but keep at least
    // _grabbableEdge pixels of the title bar visible so the user can
    // always drag it back.
    const grabbableEdge = 40.0;
    _left = _left.clamp(-_width + grabbableEdge, screenSize.width - grabbableEdge);
    _top = _top.clamp(-_titleBarHeight + grabbableEdge, screenSize.height - grabbableEdge);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // Clamp the size to not exceed screen bounds.
    _width = _width.clamp(_minWidth, screenSize.width - 40);
    _height = _height.clamp(_minHeight, screenSize.height - 40);
    _clampPosition(screenSize);

    return Positioned(
      left: _left,
      top: _top,
      child: GestureDetector(
        onTapDown: (_) => widget.onTap(),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Container(
            width: _width,
            height: _height,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                // Title bar
                _buildTitleBar(context, screenSize),
                // Body
                Expanded(
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute(
                      builder: widget.contentBuilder,
                    ),
                  ),
                ),
                // Resize handle
                _buildResizeHandle(screenSize),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, Size screenSize) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _left += details.delta.dx;
          _top += details.delta.dy;
          _clampPosition(screenSize);
        });
      },
      child: Container(
        height: _titleBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            topRight: Radius.circular(10),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResizeHandle(Size screenSize) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _width = (_width + details.delta.dx).clamp(
            _minWidth,
            screenSize.width - _left,
          );
          _height = (_height + details.delta.dy).clamp(
            _minHeight,
            screenSize.height - _top,
          );
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeDownRight,
        child: Container(
          alignment: Alignment.bottomRight,
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.drag_handle,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
