import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../models/message.dart';
import 'message_context_menu.dart';

/// Handles long-press on a message: disables system text actions, shows a
/// WeChat-style floating menu, and enables full-text selection with handles.
class MessageLongPressHandler extends StatefulWidget {
  final Message message;
  final bool isGroupMode;
  final bool hasSelectableText;
  final Widget Function({
    required bool textSelectionEnabled,
    required bool menuActive,
    required GlobalKey<SelectionAreaState> selectionAreaKey,
    required FocusNode selectionFocusNode,
  }) builder;
  final VoidCallback onReply;
  final VoidCallback onRollback;
  final VoidCallback onReEdit;
  final VoidCallback onDelete;
  final VoidCallback? onViewTrace;

  const MessageLongPressHandler({
    super.key,
    required this.message,
    required this.isGroupMode,
    required this.hasSelectableText,
    required this.builder,
    required this.onReply,
    required this.onRollback,
    required this.onReEdit,
    required this.onDelete,
    this.onViewTrace,
  });

  @override
  State<MessageLongPressHandler> createState() =>
      _MessageLongPressHandlerState();
}

class _MessageLongPressHandlerState extends State<MessageLongPressHandler> {
  final _anchorKey = GlobalKey();
  final _selectionAreaKey = GlobalKey<SelectionAreaState>();
  final _selectionFocusNode = FocusNode();
  late final LongPressGestureRecognizer _longPressRecognizer;
  bool _textSelectionEnabled = false;
  bool _menuActive = false;
  OverlayEntry? _menuOverlay;
  Rect? _menuPanelRect;
  PointerRoute? _globalDismissRoute;
  DateTime? _menuShownAt;

  @override
  void initState() {
    super.initState();
    _longPressRecognizer = LongPressGestureRecognizer(
      duration: const Duration(milliseconds: 400),
      supportedDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
      },
    )..onLongPress = _onLongPress;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _longPressRecognizer.gestureSettings =
        MediaQuery.gestureSettingsOf(context);
  }

  @override
  void dispose() {
    _removeGlobalDismissRoute();
    _removeMenuOverlay();
    _longPressRecognizer.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  void _removeMenuOverlay() {
    if (_menuOverlay?.mounted ?? false) {
      _menuOverlay!.remove();
    }
    _menuOverlay = null;
  }

  void _onMenuDismissed() {
    _removeGlobalDismissRoute();
    _menuOverlay = null;
    _menuPanelRect = null;
    _menuShownAt = null;
    if (!_menuActive && !_textSelectionEnabled) return;

    if (_textSelectionEnabled) {
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
      _selectionFocusNode.unfocus();
    }
    setState(() {
      _menuActive = false;
      _textSelectionEnabled = false;
    });
  }

  void _dismissActiveMenu() {
    if (_menuOverlay?.mounted ?? false) {
      _menuOverlay!.remove();
    }
    _onMenuDismissed();
  }

  void _installGlobalDismissRoute() {
    _removeGlobalDismissRoute();
    _globalDismissRoute = _handleGlobalPointer;
    WidgetsBinding.instance.pointerRouter
        .addGlobalRoute(_globalDismissRoute!);
  }

  void _removeGlobalDismissRoute() {
    if (_globalDismissRoute == null) return;
    WidgetsBinding.instance.pointerRouter
        .removeGlobalRoute(_globalDismissRoute!);
    _globalDismissRoute = null;
  }

  void _handleGlobalPointer(PointerEvent event) {
    if (!(_menuOverlay?.mounted ?? false)) return;
    if (event is! PointerDownEvent) return;

    // Ignore stray pointer downs right after the menu opens (same touch).
    final shownAt = _menuShownAt;
    if (shownAt != null &&
        DateTime.now().difference(shownAt) <
            const Duration(milliseconds: 200)) {
      return;
    }

    final onMenu = _menuPanelRect?.contains(event.position) ?? false;
    final onMessage =
        _anchorRect()?.inflate(28).contains(event.position) ?? false;
    if (!onMenu && !onMessage) {
      _dismissActiveMenu();
    }
  }

  Rect? _anchorRect() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  void _selectAllText() {
    final region = _selectionAreaKey.currentState?.selectableRegion;
    if (region == null) return;
    region.selectAll(SelectionChangedCause.longPress);
    _selectionFocusNode.requestFocus();
  }

  void _afterFrames(int count, VoidCallback action) {
    if (count <= 0) {
      action();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _afterFrames(count - 1, action);
    });
  }

  void _showMenu({int retries = 3}) {
    if (!mounted || (_menuOverlay?.mounted ?? false)) return;

    final rect = _anchorRect();
    if (rect == null) {
      if (retries > 0) {
        _afterFrames(1, () => _showMenu(retries: retries - 1));
      }
      return;
    }

    _removeMenuOverlay();
    _menuPanelRect = null;
    _menuOverlay = showMessageContextMenu(
      context,
      message: widget.message,
      anchorRect: rect,
      isGroupMode: widget.isGroupMode,
      onReply: widget.onReply,
      onRollback: widget.onRollback,
      onReEdit: widget.onReEdit,
      onDelete: widget.onDelete,
      onViewTrace: widget.onViewTrace,
      onDismiss: _onMenuDismissed,
      selectionAreaKey:
          widget.hasSelectableText ? _selectionAreaKey : null,
      onPanelBoundsChanged: (panelRect) {
        _menuPanelRect = panelRect;
      },
    );
    _menuShownAt = DateTime.now();
    _installGlobalDismissRoute();
    if (!_menuActive) {
      setState(() => _menuActive = true);
    }
  }

  void _onLongPress() {
    if (_menuOverlay?.mounted ?? false) return;
    HapticFeedback.mediumImpact();

    if (widget.hasSelectableText) {
      if (!_textSelectionEnabled) {
        setState(() => _textSelectionEnabled = true);
      }
      // Show menu first so the first long-press always gets feedback.
      _afterFrames(1, () {
        if (!mounted) return;
        _showMenu();
        _afterFrames(2, _selectAllText);
      });
    } else {
      _showMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTint = Theme.of(context).colorScheme.primary.withValues(
          alpha: 0.14,
        );

    return RawGestureDetector(
      key: _anchorKey,
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => _longPressRecognizer,
          (_) {},
        ),
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.builder(
            textSelectionEnabled: _textSelectionEnabled,
            menuActive: _menuActive,
            selectionAreaKey: _selectionAreaKey,
            selectionFocusNode: _selectionFocusNode,
          ),
          if (_menuActive)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selectedTint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
