import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../l10n/app_localizations.dart';
import '../services/error_handler_service.dart';

/// 去掉 `package:markdown` 给 fenced / indented code 追加的那一个结尾换行。
///
/// flutter_markdown 在 `MarkdownDelegate.formatText` 里用 `RegExp(r'\n$')` 做同样
/// 的处理。这里保持一致：显示高度与默认渲染一致，粘贴出来的代码也字节一致。
///
/// 只去**一个**换行，不做 trim —— 作者在围栏里故意留的空行是有意义的。
String codeBlockClipboardText(String rawCode) {
  if (rawCode.endsWith('\r\n')) {
    return rawCode.substring(0, rawCode.length - 2);
  }
  if (rawCode.endsWith('\n') || rawCode.endsWith('\r')) {
    return rawCode.substring(0, rawCode.length - 1);
  }
  return rawCode;
}

/// 代码块渲染体：右上角复制按钮 + 横向滚动。
///
/// 通过 [CopyableCodeBlockBuilder] 挂到 flutter_markdown 的 `pre` 分支上，
/// 外层的圆角容器 / 底色 / 裁剪仍由框架的 `codeblockDecoration` 提供。
class CopyableCodeBlock extends StatefulWidget {
  const CopyableCodeBlock({
    super.key,
    required this.code,
    required this.textStyle,
    required this.padding,
  });

  /// 已归一化（无结尾换行）的代码文本。
  final String code;

  /// 代码字形（`styleSheet.code`，monospace）。
  final TextStyle? textStyle;

  /// `styleSheet.codeblockPadding`。
  final EdgeInsets padding;

  /// 按钮预留的横向占位宽度。
  ///
  /// 长行末尾永远落在按钮下面，不预留就会遮住真实内容；代价是每块少这么多
  /// 可用宽度。最小值则保证空代码块 / 单行块不会把按钮顶出下边界裁掉
  ///（`Positioned` 子节点不参与 `Stack` 尺寸计算）。
  static const double buttonGutter = 32;

  @override
  State<CopyableCodeBlock> createState() => _CopyableCodeBlockState();
}

class _CopyableCodeBlockState extends State<CopyableCodeBlock> {
  // 每个代码块一个 controller：库的默认 `pre` 分支在所有块之间共用
  // `_preScrollController`，多代码块时 Scrollbar 会读到多重 attach 的 controller。
  final ScrollController _scrollController = ScrollController();
  bool _hovering = false;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    showTopToast(
      context,
      AppLocalizations.of(context).chat_copiedToClipboard,
      icon: Icons.check_circle,
      color: Colors.green,
    );
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 颜色直接取代码字形本身，深浅气泡自动正确，无需查 theme。
    final iconColor =
        widget.textStyle?.color ?? Theme.of(context).colorScheme.onSurface;

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            end: CopyableCodeBlock.buttonGutter,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: CopyableCodeBlock.buttonGutter,
            ),
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: widget.padding,
                child: Text(widget.code, style: widget.textStyle),
              ),
            ),
          ),
        ),
        PositionedDirectional(
          top: 4,
          end: 4,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            // 裸 GestureDetector 而非 IconButton：M3 下 IconButton 默认
            // MaterialTapTargetSize.padded 会把布局盒撑到 48×48（在 Positioned 里
            // 溢出被裁、gutter 计算失效），其 tooltip 还会引入长按识别器，
            // 与气泡的长按选择入口抢手势。只加 tap 识别器不影响横向拖拽。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _copy,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  // 常驻半透明而非 hover-only：触屏设备没有 hover。
                  opacity: _hovering ? 1.0 : 0.55,
                  child: Icon(
                    _copied ? Icons.check : Icons.copy_rounded,
                    size: 16,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 把 [CopyableCodeBlock] 挂到 markdown 的 `pre` 块上。
///
/// 关键：flutter_markdown 0.6.x 对 `pre` **不会**调用
/// `visitElementAfterWithContext` —— 该调用点只存在于 inline 分支
///（builder.dart 的 block 分支对 `pre` 是写死的 if/else，不查 `builders`）。
/// block 分支真正的入口是 `MarkdownBuilder.visitText`，所以渲染体必须从这里返回；
/// 从这里返回 `null` 会静默丢掉整段代码文本。
class CopyableCodeBlockBuilder extends MarkdownElementBuilder {
  CopyableCodeBlockBuilder({required this.styleSheet});

  final MarkdownStyleSheet styleSheet;

  /// 故意返回 `false`，尽管 `pre` 是 block syntax。
  ///
  /// 这个标志在 flutter_markdown 0.6.23 里**只有一个**消费点：
  /// `MarkdownBuilder.build()` 里 `if (value.isBlockElement()) _kBlockTags.add(key)`。
  /// 而 `_kBlockTags` 是库级 `final List`，`build()` 每次重解析都无条件跑一遍，
  /// `List.add` 又不去重 —— 返回 `true` 会让每次重解析都往这个进程级全局表里
  /// 再塞一个 `'pre'`（streaming 节流 120ms，约每秒 8 次）。渲染结果不受影响
  ///（读取全是 `.contains`，重复项无害），但 `_isBlockTag` 的线性扫描会随会话
  /// 时长无限变长。
  ///
  /// 返回 `false` 不改变任何行为：`'pre'` 本就在 `builder.dart` 的 `_kBlockTags`
  /// 静态初始化列表里，`_isBlockTag('pre')` 依然为 true，block 分支照常进，
  /// 我们照样能在 `visitText` 里通过 `builders.containsKey('pre')` 接管。
  ///
  /// 升级 flutter_markdown 需复核：若将来 `isBlockElement()` 被赋予别的语义，
  /// 这里要改回 `true`。`test/widgets/copyable_code_block_test.dart` 的路由用例
  /// 是这条的金丝雀。
  @override
  bool isBlockElement() => false;

  /// 0.6.x 不会走到这里（见类注释）；返回 null 保留兜底。
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return null;
  }

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    // preferredStyle 是 styles['pre']，映射到段落样式（非 monospace）。
    // 必须用 styleSheet.code，否则代码块字形会变。
    return CopyableCodeBlock(
      code: codeBlockClipboardText(text.text),
      textStyle: styleSheet.code,
      padding: styleSheet.codeblockPadding ?? const EdgeInsets.all(10),
    );
  }
}
