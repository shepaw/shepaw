import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_node_progress.dart';
import '../copyable_code_block.dart';
import '../markdown_link_opener.dart';
import '../store_uri_link_syntax.dart';

/// 节点输出 / 步骤正文的 Markdown 渲染。和聊天气泡同一套语法（GFM、代码块
/// 可复制、`pouch://` 链接），但可选中——执行详情里常要复制一段结果。
/// 不渲染原始 HTML（flutter_markdown 默认就不会），链接只走储物袋 / 外部浏览器。
class FlowMarkdown extends StatelessWidget {
  const FlowMarkdown(
    this.data, {
    super.key,
    this.textStyle,
    this.workspaceUris = const [],
  });

  final String data;

  /// 覆盖正文颜色 / 字号（步骤正文用小一号）。
  final TextStyle? textStyle;

  /// 解析相对链接用的工作区根（`pouch://workspaces/…`）。执行详情目前拿不到
  /// 节点的 cwd，默认为空：相对链接按「无法打开」提示，不拿去试外部应用。
  final List<String> workspaceUris;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = MarkdownStyleSheet.fromTheme(theme);
    final body = textStyle ?? theme.textTheme.bodyMedium;
    final sheet = base.copyWith(
      p: body,
      listBullet: body,
      code: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubWeb,
      inlineSyntaxes: [StoreUriLinkSyntax()],
      builders: {'pre': CopyableCodeBlockBuilder(styleSheet: sheet)},
      styleSheet: sheet,
      onTapLink: (text, href, title) {
        if (href == null || href.isEmpty) return;
        // 和聊天气泡同一个出口：储物袋 / 工作区相对路径 / 外部浏览器，
        // 打不开时提示。
        unawaited(
            openMarkdownLink(context, href, workspaceUris: workspaceUris));
      },
    );
  }
}

/// 节点最近一轮的「思考与工具调用」，默认折叠。
///
/// 第一次点开时才向主机取（[load]）——老主机不认这条请求，若一打开节点就发，
/// 每个节点都要挂 10 秒转圈。[revision]（节点状态 / 轮次）变了：展开着就
/// 立刻重取，折叠着就等下次点开再取。没有步骤时写「没有记录」；没取到
/// （超时、断线、主机报错）写「没取到」+ 重试，结果不缓存。标题始终在。
/// 每一块再各自折叠：思考按 Markdown，工具输出按
/// 等宽原文（多是命令输出）。`ExpansionTile` 折叠时不构建子树。
class FlowNodeProgressSection extends StatefulWidget {
  const FlowNodeProgressSection({
    super.key,
    required this.load,
    this.revision = '',
  });

  /// [cancel] 在面板销毁 / 换轮次时完成，调用方据此放弃还没回来的请求。
  final Future<FlowNodeProgress?> Function(Future<void> cancel) load;

  /// 节点状态 + 轮次。变了就作废已取到的步骤。
  final String revision;

  @override
  State<FlowNodeProgressSection> createState() =>
      _FlowNodeProgressSectionState();
}

class _FlowNodeProgressSectionState extends State<FlowNodeProgressSection> {
  Completer<void>? _cancel;
  int _seq = 0;
  bool _expanded = false;

  /// 当前 [FlowNodeProgressSection.revision] 下是否已经取过（含在途）。
  bool _fetched = false;
  bool _loading = false;

  /// 上一次没取到（超时、断线、老主机不认这个请求）。不当成「没有步骤」，
  /// 也不缓存：给重试按钮，收起再展开也会重取。
  bool _failed = false;
  FlowNodeProgress? _progress;

  @override
  void didUpdateWidget(FlowNodeProgressSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision) return;
    _abort();
    _fetched = false;
    _loading = false;
    _failed = false;
    _progress = null;
    if (_expanded) _fetch();
  }

  @override
  void dispose() {
    _abort();
    super.dispose();
  }

  void _abort() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _cancel = null;
  }

  void _onExpansionChanged(bool expanded) {
    _expanded = expanded;
    if (expanded && !_fetched) setState(_fetch);
  }

  /// 只改字段、不 setState：调用方要么在 setState 里调，要么在
  /// didUpdateWidget 里（随后本来就会 build）。
  void _fetch() {
    final seq = ++_seq;
    final cancel = Completer<void>();
    _cancel = cancel;
    _fetched = true;
    _loading = true;
    _failed = false;
    unawaited(_await(seq, cancel));
  }

  Future<void> _await(int seq, Completer<void> cancel) async {
    FlowNodeProgress? result;
    try {
      result = await widget.load(cancel.future);
    } catch (_) {
      result = null;
    }
    if (!mounted || seq != _seq) return;
    if (identical(_cancel, cancel)) _cancel = null;
    setState(() {
      _progress = result;
      _loading = false;
      _failed = result == null;
      if (_failed) _fetched = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final progress = _progress;
    final known = !_loading && progress != null && !progress.isEmpty;
    return Container(
      key: const ValueKey('node-progress'),
      decoration: BoxDecoration(
        border:
            Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('node-progress-tile'),
        dense: true,
        initiallyExpanded: false,
        onExpansionChanged: _onExpansionChanged,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.psychology_alt_outlined, size: 18),
        title: Text(l10n.flow_nodeProgressTitle,
            style: theme.textTheme.titleSmall),
        subtitle: known
            ? Text(
                l10n.flow_nodeProgressSummary(
                    progress.thoughtCount, progress.toolCount),
                style: muted,
              )
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            Padding(
              key: const ValueKey('node-progress-loading'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.flow_nodeProgressLoading,
                      style: theme.textTheme.bodySmall),
                ],
              ),
            )
          else if (_failed)
            Padding(
              key: const ValueKey('node-progress-failed'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child:
                        Text(l10n.flow_nodeProgressUnavailable, style: muted),
                  ),
                  TextButton(
                    key: const ValueKey('node-progress-retry'),
                    onPressed: () => setState(_fetch),
                    child: Text(l10n.common_retry),
                  ),
                ],
              ),
            )
          else if (!known)
            // 没记过步骤（惜宝节点、远程 worker、老运行）。
            Padding(
              key: const ValueKey('node-progress-empty'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.flow_nodeProgressEmpty, style: muted),
            )
          else ...[
            if (progress.omitted > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(l10n.flow_nodeProgressOmitted(progress.omitted),
                    style: muted),
              ),
            for (var i = 0; i < progress.blocks.length; i++)
              _BlockTile(index: i, block: progress.blocks[i]),
          ],
        ],
      ),
    );
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile({required this.index, required this.block});

  final int index;
  final FlowProgressBlock block;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = block.failed
        ? Icons.error_outline
        : block.isThought
            ? Icons.lightbulb_outline
            : Icons.build_outlined;
    final title = block.title.isNotEmpty
        ? block.title
        : (block.isThought
            ? l10n.flow_nodeProgressThought
            : l10n.flow_nodeProgressTool);
    final content = block.content.trim();
    return ExpansionTile(
      key: ValueKey('node-progress-block-$index'),
      dense: true,
      initiallyExpanded: false,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(icon,
          size: 16, color: block.failed ? scheme.error : scheme.primary),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium),
      subtitle: block.summary.isEmpty
          ? null
          : Text(block.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace', color: scheme.onSurfaceVariant)),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (content.isEmpty)
          const SizedBox.shrink()
        else if (block.isThought)
          FlowMarkdown(content,
              textStyle: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant))
        else
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              content,
              style:
                  theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
      ],
    );
  }
}
