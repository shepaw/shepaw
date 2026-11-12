import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_node_progress.dart';
import '../../screens/storage_directory_opener.dart';
import '../../services/store_open_service.dart';
import '../../storage/store_protocol.dart';
import '../copyable_code_block.dart';
import '../store_uri_link_syntax.dart';

/// 节点输出 / 步骤正文的 Markdown 渲染。和聊天气泡同一套语法（GFM、代码块
/// 可复制、`pouch://` 链接），但可选中——执行详情里常要复制一段结果。
/// 不渲染原始 HTML（flutter_markdown 默认就不会），链接只走储物袋 / 外部浏览器。
class FlowMarkdown extends StatelessWidget {
  const FlowMarkdown(this.data, {super.key, this.textStyle});

  final String data;

  /// 覆盖正文颜色 / 字号（步骤正文用小一号）。
  final TextStyle? textStyle;

  static Future<void> _openLink(BuildContext context, String href) async {
    final pouch = isPouchUri(href) ? href : null;
    if (pouch != null) {
      registerStorageDirectoryOpener();
      await StoreOpenService.instance.openStoreUri(context, pouch);
      return;
    }
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

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
        unawaited(_openLink(context, href));
      },
    );
  }
}

/// 节点最近一轮的「思考与工具调用」，默认折叠。
///
/// 点开节点时才向主机取（[load]）；节点状态 / 轮次变了由调用方换 key 重取。
/// 每一块再各自折叠：思考按 Markdown，工具输出按等宽原文（多是命令输出）。
/// `ExpansionTile` 折叠时不构建子树，几十块长正文也不会拖慢面板。
class FlowNodeProgressSection extends StatefulWidget {
  const FlowNodeProgressSection({super.key, required this.load});

  /// [cancel] 在面板销毁时完成，调用方据此放弃还没回来的请求。
  final Future<FlowNodeProgress?> Function(Future<void> cancel) load;

  @override
  State<FlowNodeProgressSection> createState() =>
      _FlowNodeProgressSectionState();
}

class _FlowNodeProgressSectionState extends State<FlowNodeProgressSection> {
  final Completer<void> _cancel = Completer<void>();
  FlowNodeProgress? _progress;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    if (!_cancel.isCompleted) _cancel.complete();
    super.dispose();
  }

  Future<void> _fetch() async {
    FlowNodeProgress? result;
    try {
      result = await widget.load(_cancel.future);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    setState(() {
      _progress = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) {
      return Padding(
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
      );
    }
    final progress = _progress;
    // 老主机 / 没记过步骤（惜宝节点、远程 worker）：不占位。
    if (progress == null || progress.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('node-progress'),
      decoration: BoxDecoration(
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('node-progress-tile'),
        dense: true,
        initiallyExpanded: false,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.psychology_alt_outlined, size: 18),
        title: Text(l10n.flow_nodeProgressTitle,
            style: theme.textTheme.titleSmall),
        subtitle: Text(
          l10n.flow_nodeProgressSummary(
              progress.thoughtCount, progress.toolCount),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          if (progress.omitted > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(l10n.flow_nodeProgressOmitted(progress.omitted),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          for (var i = 0; i < progress.blocks.length; i++)
            _BlockTile(index: i, block: progress.blocks[i]),
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
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
      ],
    );
  }
}
