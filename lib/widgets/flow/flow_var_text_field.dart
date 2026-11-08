import 'package:flutter/material.dart';

import '../../controllers/flow/flow_references.dart';

/// 带 `{{` 逐级变量列表的输入框。
///
/// 控制器由调用方持有。光标停在未闭合的 `{{` 里时，在输入框下面列出当前这一层；
/// 点有下一级的项会补上「名字.」并留在列表里，点叶子才补 `}}`。
class FlowVarTextField extends StatefulWidget {
  const FlowVarTextField({
    super.key,
    required this.fieldKey,
    required this.controller,
    this.roots = const [],
    this.enabled = true,
    this.readOnly = false,
    this.minLines,
    this.maxLines = 1,
    this.grow = false,
    this.keyboardType,
    this.textInputAction,
    this.decoration,
    this.onChanged,
    this.onEditingComplete,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final List<FlowVarNode> roots;
  final bool enabled;
  final bool readOnly;
  final int? minLines;

  /// [grow] 为 false 时的行数上限。
  final int maxLines;

  /// true：随内容增高（提示词这种长文本）。
  final bool grow;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final InputDecoration? decoration;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;

  @override
  State<FlowVarTextField> createState() => _FlowVarTextFieldState();
}

class _FlowVarTextFieldState extends State<FlowVarTextField> {
  FlowVarSuggest? _suggest;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    // 框里可能已经停在未闭合的 {{ 上。这一帧还在 build，等画完再刷列表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didUpdateWidget(covariant FlowVarTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_sync);
    widget.controller.addListener(_sync);
    // 换了控制器就收起旧列表。这里还在 build 里，不能 setState。
    _suggest = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final c = widget.controller;
    final next = widget.roots.isEmpty
        ? null
        : FlowReferences.suggest(
            text: c.text,
            cursor: c.selection.extentOffset,
            roots: widget.roots,
          );
    if (_same(_suggest, next)) return;
    setState(() => _suggest = next);
  }

  bool _same(FlowVarSuggest? a, FlowVarSuggest? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == null && b == null;
    if (a.filter != b.filter ||
        a.replaceFrom != b.replaceFrom ||
        a.cursor != b.cursor ||
        a.options.length != b.options.length) {
      return false;
    }
    for (var i = 0; i < a.options.length; i++) {
      if (a.options[i].segment != b.options[i].segment) return false;
    }
    return true;
  }

  /// 点一级变量。有下一级就补上「名字.」并留在列表里，叶子才补 `}}`。
  void _pick(FlowVarNode node) {
    final suggest = _suggest;
    if (suggest == null) return;
    final piece = node.hasChildren ? '${node.segment}.' : '${node.segment} }}';
    final c = widget.controller;
    final text = c.text;
    final from = suggest.replaceFrom.clamp(0, text.length);
    final to = suggest.cursor.clamp(from, text.length);
    final next = text.replaceRange(from, to, piece);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: from + piece.length),
    );
    // 程序改控制器不会走 TextField.onChanged，调用方靠这个发出草稿。
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final suggest = _suggest;
    final matches = suggest?.matches;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: widget.fieldKey,
          controller: widget.controller,
          enabled: widget.enabled,
          readOnly: widget.readOnly,
          minLines: widget.minLines,
          maxLines: widget.grow ? null : widget.maxLines,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          decoration: widget.decoration,
          onChanged: widget.onChanged,
          onEditingComplete: widget.onEditingComplete,
        ),
        if (suggest != null)
          Card(
            key: const ValueKey('var-suggest'),
            margin: const EdgeInsets.only(top: 4),
            elevation: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: matches == null || matches.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('没有匹配的变量'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        for (final node in matches)
                          InkWell(
                            key: ValueKey('var-opt-${node.segment}'),
                            // 按下就写入。等 onTap，焦点先离开输入框，点击会被吃掉。
                            onTapDown: (_) => _pick(node),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        text: node.segment,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                          fontFamily: 'monospace',
                                        ),
                                        children: [
                                          if (node.hint.isNotEmpty)
                                            TextSpan(
                                              text: '  ${node.hint}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                fontFamily: null,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (node.hasChildren)
                                    Icon(Icons.chevron_right,
                                        size: 18,
                                        color: scheme.onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}
