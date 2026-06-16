import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/message.dart';
import '../../providers/app_state.dart';
import '../../utils/message_utils.dart';
import '../../l10n/app_localizations.dart';
import '../../services/error_handler_service.dart';

/// A single action in the message floating context menu.
class MessageMenuAction {
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const MessageMenuAction({
    required this.label,
    required this.onTap,
    this.color,
  });
}

/// Shows a WeChat-style floating context menu anchored to [anchorRect].
///
/// Returns the [OverlayEntry] so the caller can dismiss it.
OverlayEntry showMessageContextMenu(
  BuildContext context, {
  required Message message,
  required Rect anchorRect,
  required bool isGroupMode,
  required VoidCallback onReply,
  required VoidCallback onRollback,
  required VoidCallback onReEdit,
  required VoidCallback onDelete,
  VoidCallback? onViewTrace,
  VoidCallback? onDismiss,
  GlobalKey<SelectionAreaState>? selectionAreaKey,
  void Function(Rect panelRect)? onPanelBoundsChanged,
}) {
  final menuL10n = AppLocalizations.of(context);
  final userId =
      Provider.of<AppState>(context, listen: false).currentUser?.id ?? 'user';
  final primaryColor = Theme.of(context).colorScheme.primary;

  OverlayEntry? menuEntry;

  void closeMenu({VoidCallback? afterClose}) {
    afterClose?.call();
    menuEntry?.remove();
    menuEntry = null;
    onDismiss?.call();
  }

  void copyText() {
    final region = selectionAreaKey?.currentState?.selectableRegion;
    if (region != null) {
      region.copySelection(SelectionChangedCause.toolbar);
    } else {
      Clipboard.setData(ClipboardData(text: message.content));
    }
    showTopToast(
      context,
      menuL10n.chat_copiedToClipboard,
      icon: Icons.check_circle,
      color: Colors.green,
    );
  }

  final actions = <MessageMenuAction>[
    if (onViewTrace != null)
      MessageMenuAction(
        label: menuL10n.chat_viewTrace,
        onTap: () => closeMenu(afterClose: onViewTrace),
      ),
    MessageMenuAction(
      label: menuL10n.common_copy,
      onTap: () => closeMenu(afterClose: copyText),
    ),
    if (!message.from.isUser || isGroupMode)
      MessageMenuAction(
        label: menuL10n.common_reply,
        onTap: () => closeMenu(afterClose: onReply),
      ),
    if (message.type == MessageType.image || message.type == MessageType.file)
      MessageMenuAction(
        label: menuL10n.chat_download,
        onTap: () => closeMenu(
          afterClose: () => showTopToast(
            context,
            menuL10n.common_featureComingSoon,
            icon: Icons.info_outline,
          ),
        ),
      ),
    if (message.from.isUser) ...[
      MessageMenuAction(
        label: menuL10n.chat_rollback,
        color: Colors.orange,
        onTap: () => closeMenu(afterClose: onRollback),
      ),
      MessageMenuAction(
        label: menuL10n.chat_reEdit,
        color: primaryColor,
        onTap: () => closeMenu(afterClose: onReEdit),
      ),
    ],
    if (MessageUtils.canDeleteMessage(message, userId))
      MessageMenuAction(
        label: menuL10n.common_delete,
        color: Colors.red,
        onTap: () => closeMenu(afterClose: onDelete),
      ),
  ];

  menuEntry = OverlayEntry(
    builder: (overlayContext) => _MessageFloatingMenuOverlay(
      anchorRect: anchorRect,
      actions: actions,
      onPanelBoundsChanged: onPanelBoundsChanged,
    ),
  );

  final overlayState = Overlay.of(context, rootOverlay: true);
  overlayState.insert(menuEntry!);
  return menuEntry!;
}

/// WeChat-style dark floating toolbar with a downward arrow.
class _MessageFloatingMenuOverlay extends StatefulWidget {
  final Rect anchorRect;
  final List<MessageMenuAction> actions;
  final void Function(Rect panelRect)? onPanelBoundsChanged;

  const _MessageFloatingMenuOverlay({
    required this.anchorRect,
    required this.actions,
    this.onPanelBoundsChanged,
  });

  @override
  State<_MessageFloatingMenuOverlay> createState() =>
      _MessageFloatingMenuOverlayState();
}

class _MessageFloatingMenuOverlayState
    extends State<_MessageFloatingMenuOverlay> {
  final _panelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportBounds());
  }

  void _reportBounds() {
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onPanelBoundsChanged?.call(
      box.localToGlobal(Offset.zero) & box.size,
    );
  }

  static const _menuBg = Color(0xFF4C4C4C);
  static const _arrowSize = 8.0;
  static const _gap = 10.0;
  static const _menuBarHeight = 42.0;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    const horizontalMargin = 12.0;
    final maxMenuWidth = screenSize.width - horizontalMargin * 2;
    final estimatedWidth = _estimateMenuWidth(context, widget.actions);
    final menuWidth = estimatedWidth.clamp(0.0, maxMenuWidth);
    final needsScroll = estimatedWidth > maxMenuWidth;

    final anchorCenterX = widget.anchorRect.center.dx;
    var left = anchorCenterX - menuWidth / 2;
    left = left.clamp(
      horizontalMargin,
      screenSize.width - menuWidth - horizontalMargin,
    );

    final showAbove = widget.anchorRect.center.dy > screenSize.height * 0.4;
    final arrowLeft =
        (anchorCenterX - left - _arrowSize).clamp(8.0, menuWidth - 20.0);
    final panelHeight = _menuBarHeight + _arrowSize;

    var top = showAbove
        ? widget.anchorRect.top - _gap - panelHeight
        : widget.anchorRect.bottom + _gap;
    top = top.clamp(
      padding.top + 4,
      screenSize.height - panelHeight - padding.bottom - 4,
    );

    final menuWidget = SizedBox(
      width: menuWidth,
      height: _menuBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _menuBg,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: needsScroll
                ? const BouncingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            child: _buildMenuContent(context, widget.actions),
          ),
        ),
      ),
    );

    final arrowWidget = Padding(
      padding: EdgeInsets.only(left: arrowLeft),
      child: CustomPaint(
        size: const Size(_arrowSize * 2, _arrowSize),
        painter: _MenuArrowPainter(
          color: _menuBg,
          pointsUp: !showAbove,
        ),
      ),
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: showAbove
          ? [menuWidget, arrowWidget]
          : [arrowWidget, menuWidget],
    );

    return Positioned(
      key: _panelKey,
      left: left,
      top: top,
      width: menuWidth,
      child: Material(
        color: Colors.transparent,
        child: column,
      ),
    );
  }
}

double _estimateMenuWidth(
  BuildContext context,
  List<MessageMenuAction> actions,
) {
    const style = TextStyle(color: Colors.white, fontSize: 14);
    const buttonHPadding = 12.0;
    const dividerWidth = 0.5;
    var width = 0.0;
    for (var i = 0; i < actions.length; i++) {
      final painter = TextPainter(
        text: TextSpan(text: actions[i].label, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      width += painter.width + buttonHPadding * 2;
      if (i < actions.length - 1) width += dividerWidth;
    }
  return width;
}

Widget _buildMenuContent(
  BuildContext context,
  List<MessageMenuAction> actions,
) {
    return IntrinsicHeight(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0)
              Container(
                width: 0.5,
                margin: const EdgeInsets.symmetric(vertical: 10),
                color: Colors.white24,
              ),
            _MenuActionButton(action: actions[i]),
          ],
        ],
      ),
    );
}

class _MenuActionButton extends StatelessWidget {
  final MessageMenuAction action;

  const _MenuActionButton({required this.action});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: action.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Text(
          action.label,
          style: TextStyle(
            color: action.color ?? Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
          maxLines: 1,
          softWrap: false,
        ),
      ),
    );
  }
}

class _MenuArrowPainter extends CustomPainter {
  final Color color;
  final bool pointsUp;

  const _MenuArrowPainter({required this.color, required this.pointsUp});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    if (pointsUp) {
      path.moveTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MenuArrowPainter oldDelegate) =>
      color != oldDelegate.color || pointsUp != oldDelegate.pointsUp;
}
