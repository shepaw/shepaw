import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../utils/layout_utils.dart';
import '../../screens/flow_library_screen.dart';
import '../../utils/session_utils.dart';
import '../session_folders.dart';
import 'session_row_menu.dart';

/// 折叠组展开后的会话行（折叠方案 §2.2）：就在会话列表里展开，不开新页面。
///
/// 只读、可以分叉到私聊；分页按主机给的游标走。这里画的是一段普通的行，不是
/// [ListView] —— 外层（会话列表）已经在滚，嵌套可滚动会抢手势。
class SessionFolderItems extends StatefulWidget {
  const SessionFolderItems({
    super.key,
    required this.peerId,
    required this.agentId,
    required this.folder,
    this.parentSession = '',
    this.client,
    this.onOpen,
    this.onForked,
  });

  final String peerId;

  /// 主机上的 Agent id（不是本机的 RemoteAgent.id）。
  final String agentId;
  final SessionFolderKind folder;
  final String parentSession;
  final HubFoldedSessions? client;

  /// 点一项：打开它的只读记录（工作流节点走运行视图，群聊走群聊视角）。
  final void Function(FoldedSession session)? onOpen;

  /// 分叉成功后，新私聊会话的 id；调用方在这里刷新平铺名单。
  final void Function(String sessionId)? onForked;

  @override
  State<SessionFolderItems> createState() => _SessionFolderItemsState();
}

class _SessionFolderItemsState extends State<SessionFolderItems> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  final List<FoldedSession> _items = [];
  String? _cursor;
  bool _loading = false;
  bool _failed = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_loading || (_started && _cursor == null)) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final page = await _client.page(
      widget.peerId,
      widget.agentId,
      widget.folder,
      cursor: _cursor ?? '',
      parentSession: widget.parentSession,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _started = true;
      if (page == null) {
        _failed = true;
        // 第一页失败时允许重试。
        if (_items.isEmpty) _started = false;
        return;
      }
      _items.addAll(page.items);
      _cursor = page.cursor;
    });
  }

  Future<void> _fork(FoldedSession session) async {
    final result =
        await _client.fork(widget.peerId, widget.agentId, session.sessionId);
    if (!mounted) return;
    final id = result.sessionId;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(id == null
          ? (result.error ?? AppLocalizations.of(context).folder_forkFailed)
          : AppLocalizations.of(context).folder_forked),
    ));
    if (id != null) widget.onForked?.call(id);
  }

  String _subtitle(AppLocalizations l10n, FoldedSession session) {
    final parts = <String>[];
    if (session.isFlow && session.nodeKey.isNotEmpty) {
      parts.add(l10n.folder_node(session.nodeKey));
    }
    if (session.fromAgent.isNotEmpty)
      parts.add(l10n.folder_from(session.fromAgent));
    if (session.hostName.isNotEmpty) parts.add(session.hostName);
    if (session.messageCount != null)
      parts.add(l10n.folder_messageCount(session.messageCount!));
    return parts.join(' · ');
  }

  /// 组里的一行。和私聊会话行一个规矩：「更多」平时不占位，桌面悬停（或菜单
  /// 打开期间）才出现；移动端没有悬停，改成长按弹底部菜单。
  Widget _sessionRow(
    BuildContext context,
    AppLocalizations l10n,
    FoldedSession session,
    String subtitle,
  ) {
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    return SessionRowHoverHost(
      enabled: isDesktop,
      builder: (context, hover) {
        return ListTile(
          title: Text(_title(session),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          onTap: widget.onOpen == null ? null : () => widget.onOpen!(session),
          onLongPress:
              isDesktop ? null : () => _showForkSheet(context, l10n, session),
          trailing: hover.showMore
              ? Builder(builder: (buttonContext) {
                  return IconButton(
                    tooltip: l10n.folder_more,
                    icon: const Icon(Icons.more_vert, size: 20),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 32, height: 32),
                    onPressed: () => hover.holdWhileOpen(
                      () =>
                          _showForkMenu(context, buttonContext, l10n, session),
                    ),
                  );
                })
              : null,
        );
      },
    );
  }

  /// 桌面：在「更多」按钮旁弹出下拉菜单（与会话行同一套路）。
  Future<void> _showForkMenu(
    BuildContext context,
    BuildContext buttonContext,
    AppLocalizations l10n,
    FoldedSession session,
  ) async {
    final overlayBox =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    if (overlayBox == null || buttonBox == null || !buttonBox.hasSize) return;
    final rect =
        overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero)) &
            buttonBox.size;
    final choice = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromSize(rect, overlayBox.size),
      items: [
        PopupMenuItem<String>(value: 'fork', child: Text(l10n.folder_fork)),
      ],
    );
    if (choice == 'fork') await _fork(session);
  }

  /// 移动端：长按弹底部菜单（没有悬停，这是唯一的入口）。
  Future<void> _showForkSheet(
    BuildContext context,
    AppLocalizations l10n,
    FoldedSession session,
  ) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call_split),
              title: Text(l10n.folder_fork),
              onTap: () => Navigator.pop(sheetContext, 'fork'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'fork' && context.mounted) await _fork(session);
  }

  /// 主机给的标题里可能整段是引擎标签或 `[implicit]` 提示：清掉，清完没东西
  /// 就退回会话 id。
  String _title(FoldedSession session) =>
      SessionUtils.cleanClaudeSessionTitle(session.title) ?? session.sessionId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = <Widget>[];
    // 工作流组顺手带上流程库的入口：设计、演练、运行都从这里进。原来它在组
    // 明细页的标题栏，现在是展开区里的第一行。
    if (widget.folder == SessionFolderKind.flow) {
      rows.add(ListTile(
        leading: const Icon(Icons.account_tree_outlined, size: 20),
        title: Text(l10n.flow_libraryTitle),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => FlowLibraryScreen(peerId: widget.peerId),
        )),
      ));
    }
    // 工作流按运行分组，其余按时间平铺（折叠方案 §2.2）。
    String? lastRun;
    for (final session in _items) {
      if (widget.folder == SessionFolderKind.flow &&
          session.runId.isNotEmpty &&
          session.runId != lastRun) {
        lastRun = session.runId;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(l10n.folder_runHeader(session.runId),
              style: Theme.of(context).textTheme.labelMedium),
        ));
      }
      rows.add(_sessionRow(context, l10n, session, _subtitle(l10n, session)));
    }
    if (_loading && _items.isEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (_failed && _items.isEmpty) {
      rows.add(Center(
        child: TextButton(onPressed: _more, child: Text(l10n.folder_retry)),
      ));
    } else if (_items.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(l10n.folder_empty,
            style: TextStyle(fontSize: 13, color: Colors.grey[600])),
      ));
    } else if (_cursor != null || _loading) {
      rows.add(Center(
        child: _loading
            ? const CircularProgressIndicator()
            : TextButton(onPressed: _more, child: Text(l10n.folder_loadMore)),
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}
