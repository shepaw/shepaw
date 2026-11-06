import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../utils/layout_utils.dart';
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
    this.onViewRun,
    this.onForked,
  });

  final String peerId;

  /// 主机上的 Agent id（不是本机的 RemoteAgent.id）。
  final String agentId;
  final SessionFolderKind folder;
  final String parentSession;
  final HubFoldedSessions? client;

  /// 点一项：打开它的会话（工作流节点是私聊，其余是只读记录）。
  final void Function(FoldedSession session)? onOpen;

  /// 工作流条目的次级入口：「查看运行」。
  final void Function(FoldedSession session)? onViewRun;

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
    String subtitle, {
    String? title,
  }) {
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    return SessionRowHoverHost(
      enabled: isDesktop,
      builder: (context, hover) {
        return ListTile(
          title: Text(title ?? _title(session),
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
        if (session.isFlow && widget.onViewRun != null)
          PopupMenuItem<String>(
            value: 'run',
            child: Text(l10n.flow_viewRun),
          ),
        PopupMenuItem<String>(value: 'fork', child: Text(l10n.folder_fork)),
      ],
    );
    // showMenu 是一个路由：等它关掉再回来时，列表行可能已经被替换 / 卸载
    // （分组刷新、筛选变化）。和移动端 sheet 路径一致，先确认 context 还
    // 活着，否则访问 widget 会抛 "This widget has been unmounted"。
    if (!context.mounted) return;
    if (choice == 'run') {
      widget.onViewRun?.call(session);
    } else if (choice == 'fork') {
      await _fork(session);
    }
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
            if (session.isFlow && widget.onViewRun != null)
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(l10n.flow_viewRun),
                onTap: () => Navigator.pop(sheetContext, 'run'),
              ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: Text(l10n.folder_fork),
              onTap: () => Navigator.pop(sheetContext, 'fork'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'run' && context.mounted) {
      widget.onViewRun?.call(session);
    } else if (choice == 'fork' && context.mounted) {
      await _fork(session);
    }
  }

  /// 工作流组里要画出来的记录。同一次运行只留一条；节点名和
  /// `工作流 <run id>` 是流程步骤的占位，不是用户发起时说的那句话。
  static List<FoldedSession> flowInitiationRecords(List<FoldedSession> items) {
    final seen = <String>{};
    final out = <FoldedSession>[];
    for (final session in items) {
      if (session.runId.isEmpty || _isFlowStepPlaceholder(session)) continue;
      if (!seen.add(session.runId)) continue;
      if (SessionUtils.firstSentenceTitle(session.title) == null) continue;
      out.add(session);
    }
    return out;
  }

  static bool _isFlowStepPlaceholder(FoldedSession session) {
    final title = session.title.trim();
    if (title.isEmpty) return true;
    if (session.nodeKey.isNotEmpty && title == session.nodeKey) return true;
    return session.runId.isNotEmpty && title == '工作流 ${session.runId}';
  }

  /// 主机给的标题里可能整段是引擎标签或 `[implicit]` 提示：清掉，清完没东西
  /// 就退回会话 id。
  String _title(FoldedSession session) {
    final cleaned = SessionUtils.cleanClaudeSessionTitle(session.title);
    if (cleaned != null) return cleaned;
    // 清完没东西（整段是引擎包装）：用时间兜底，别把会话 id（UUID）顶上去。
    final stamp = SessionUtils.shortDateTime(session.updatedAt);
    return stamp.isEmpty ? session.sessionId : stamp;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = <Widget>[];
    // 工作流组只列发起过的运行，一条运行一行，标题是启动时的第一句话。
    // 流程库和模板不从这里进。
    final sessions = widget.folder == SessionFolderKind.flow
        ? flowInitiationRecords(_items)
        : _items;
    for (final session in sessions) {
      final title = widget.folder == SessionFolderKind.flow
          ? (SessionUtils.firstSentenceTitle(session.title) ?? '')
          : null;
      rows.add(_sessionRow(
        context,
        l10n,
        session,
        widget.folder == SessionFolderKind.flow ? '' : _subtitle(l10n, session),
        title: title,
      ));
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
    } else if (sessions.isEmpty && _cursor == null) {
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
