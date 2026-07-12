import 'package:flutter/material.dart';

/// A wrapper widget that allows long content to be collapsed/expanded.
///
/// Useful for "thinking" messages or verbose agent output that should
/// be collapsed by default or auto-collapsed when streaming finishes.
///
/// When collapsed, only the header is shown — content is fully hidden.
class CollapsibleMessageBubble extends StatefulWidget {
  final Widget child;
  final bool initiallyCollapsed;
  final bool autoCollapseOnComplete;
  final bool isStreaming;
  final String? title;
  final bool isMyMessage;

  const CollapsibleMessageBubble({
    Key? key,
    required this.child,
    this.initiallyCollapsed = false,
    this.autoCollapseOnComplete = false,
    this.isStreaming = false,
    this.title,
    this.isMyMessage = false,
  }) : super(key: key);

  @override
  State<CollapsibleMessageBubble> createState() =>
      _CollapsibleMessageBubbleState();
}

class _CollapsibleMessageBubbleState extends State<CollapsibleMessageBubble> {
  late bool _isCollapsed;
  bool _wasStreaming = false;

  @override
  void initState() {
    super.initState();
    _isCollapsed = widget.initiallyCollapsed;
    _wasStreaming = widget.isStreaming;
  }

  @override
  void didUpdateWidget(covariant CollapsibleMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Detect streaming completion: was streaming, now not streaming
    if (widget.autoCollapseOnComplete &&
        _wasStreaming &&
        !widget.isStreaming) {
      setState(() {
        _isCollapsed = true;
      });
    }
    _wasStreaming = widget.isStreaming;
  }

  void _toggle() {
    setState(() {
      _isCollapsed = !_isCollapsed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final headerColor =
        widget.isMyMessage ? Colors.white70 : Colors.black54;
    final chevronColor =
        widget.isMyMessage ? Colors.white60 : Colors.black45;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header row with title and toggle
        GestureDetector(
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: EdgeInsets.only(bottom: _isCollapsed ? 0 : 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isCollapsed
                      ? Icons.chevron_right
                      : Icons.expand_more,
                  size: 18,
                  color: chevronColor,
                ),
                const SizedBox(width: 2),
                if (widget.title != null)
                  Flexible(
                    child: Text(
                      widget.title!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: headerColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (widget.isStreaming) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(headerColor),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!_isCollapsed) widget.child,
      ],
    );
  }
}
