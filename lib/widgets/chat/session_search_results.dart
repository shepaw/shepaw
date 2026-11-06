import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import 'folded_session_open.dart';
import '../../services/local_database_service.dart';
import '../../services/message_search_service.dart';
import '../../services/session/folded_target.dart';
import '../../theme/app_theme.dart';
import '../../utils/session_utils.dart';
import 'chat_panel_scope.dart';

/// 抽屉内搜索的结果视图（查询非空时作为抽屉主体）。
///
/// - 按会话名称命中的会话：点击进入该会话；
/// - 按消息内容命中的结果：按会话分组展示（关键词高亮），点击定位到消息。
///
/// 所有点击先经 [closePanelRoute] 关闭面板（抽屉 pop 路由；停靠面板
/// 保留）再回调，与 [SessionListPanel] 的行为一致。
///
/// 用 StatefulWidget 是为了按查询发起一次消息搜索，而不是在 build 里
/// 重建 Future：消息搜索是 `content LIKE '%q%'` 全表扫（命中不了索引）
/// 且带几百个 channelId。查询节流在抽屉搜索框，这里只消费已提交的词。
///
/// 折叠组（群聊 / 工作流 / 引擎客户端 / 引擎终端）里的会话本机没有副本 ——
/// 主机折叠视图只平铺私聊，本地那份镜像会被剪掉 —— 所以它们另外问一次主机，
/// 结果单独成一段（只读，带来源角标）。见 [resolveFoldedTarget]。
class SessionSearchResults extends StatefulWidget {
  const SessionSearchResults({
    super.key,
    required this.query,
    required this.sessions,
    required this.searchService,
    required this.onSwitchSession,
    required this.onLocateMessage,
    this.groupChannel,
    this.agentId,
    this.foldedTarget,
    this.hubClient,
    this.database,
  });

  /// 当前搜索词（非空）。
  final String query;

  /// 抽屉里的全部会话：名称匹配 + channelId → 会话名映射。
  final List<Channel> sessions;

  final MessageSearchService searchService;

  /// 点击名称命中的会话 → 进入会话。
  final ValueChanged<String> onSwitchSession;

  /// 点击内容命中的消息 → 定位（同会话滚动，跨会话切换后高亮）。
  final void Function(Message message, String? channelId) onLocateMessage;

  /// 群聊模式传入，用于区分会话搜索结果的图标样式。
  final Channel? groupChannel;

  /// 当前 Agent。用来反查折叠组要问的主机；为空（群聊模式）就只搜本机。
  final String? agentId;

  /// 折叠组要问的主机。测试里直接给；为空时按 [agentId] 查库解析。
  final ({String peerId, String remoteAgentId})? foldedTarget;

  /// 问主机用的客户端。测试里换成假的；为空时用 [HubFoldedSessions]。
  final HubFoldedSessions? hubClient;

  /// 查库用的库。测试里可以换；为空时用 [LocalDatabaseService]。
  final LocalDatabaseService? database;

  @override
  State<SessionSearchResults> createState() => _SessionSearchResultsState();
}

class _SessionSearchResultsState extends State<SessionSearchResults> {
  List<MessageSearchResult> _results = const [];
  bool _loading = false;
  int _generation = 0;

  /// 主机那边（折叠组）的命中；本机没有这些会话的副本，得单独问一次。
  List<SessionSearchHit> _hubHits = const [];
  bool _hubLoading = false;
  HubFoldedSessions? _hubInstance;

  /// 群聊模式、本机 Agent 这些没有折叠目标的场景不该去碰连接管理器，
  /// 所以等真要问主机时才建。
  HubFoldedSessions get _hub =>
      _hubInstance ??= widget.hubClient ?? HubFoldedSessions();
  ({String peerId, String remoteAgentId})? _target;

  bool get _isGroupMode => widget.groupChannel != null;

  @override
  void initState() {
    super.initState();
    _target = widget.foldedTarget;
    final q = widget.query.trim();
    if (q.isEmpty) {
      // 注入了目标就不用查库；没注入的等第一次查完再补搜。
      if (_target == null) unawaited(_resolveTarget());
      return;
    }
    _loading = true;
    _hubLoading = _target != null;
    _runSearch(q);
    unawaited(_runHubSearch(q));
    if (_target == null) unawaited(_resolveTarget());
  }

  /// 折叠组要问哪个主机。查库是异步的，等它回来再补一次主机搜索（那时本机
  /// 那一轮已经跑过，[didUpdateWidget] 不会再触发）。
  Future<void> _resolveTarget() async {
    final target = await resolveFoldedTarget(
      agentId: widget.agentId,
      isGroupMode: _isGroupMode,
      database: widget.database,
    );
    if (!mounted || target == null) return;
    final q = widget.query.trim();
    if (q.isEmpty) {
      setState(() => _target = target);
      return;
    }
    setState(() {
      _target = target;
      _hubLoading = true;
    });
    await _runHubSearch(q);
  }

  @override
  void didUpdateWidget(SessionSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.query.trim();
    if (q == oldWidget.query.trim() && !_sessionIdsChanged(oldWidget)) {
      return;
    }
    // 字段直接改：didUpdateWidget 发生在本帧 build 之前，下一行 build
    // 就能看到加载态。不能在这里 setState。
    if (q.isEmpty) {
      _generation++;
      _results = const [];
      _hubHits = const [];
      _loading = false;
      _hubLoading = false;
      return;
    }
    _results = const [];
    _hubHits = const [];
    _loading = true;
    _hubLoading = _target != null;
    _runSearch(q);
    unawaited(_runHubSearch(q));
  }

  Future<void> _runHubSearch(String q) async {
    final target = _target;
    if (target == null) {
      if (mounted && _hubLoading) setState(() => _hubLoading = false);
      return;
    }
    final generation = _generation;
    final hits = await _hub.search(
      target.peerId,
      q,
      agentId: target.remoteAgentId,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _hubHits = hits;
      _hubLoading = false;
    });
  }

  bool _sessionIdsChanged(SessionSearchResults oldWidget) {
    final previous = oldWidget.sessions;
    final next = widget.sessions;
    if (identical(previous, next)) return false;
    if (previous.length != next.length) return true;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i].id != next[i].id) return true;
    }
    return false;
  }

  Future<void> _runSearch(String q) async {
    final generation = ++_generation;
    List<MessageSearchResult> results;
    try {
      results = await widget.searchService.searchMessages(
        query: q,
        channelIds: [for (final s in widget.sessions) s.id],
        limit: 100,
      );
    } catch (_) {
      results = const [];
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  String _sessionLabel(Channel session) {
    return SessionUtils.cleanClaudeSessionTitle(session.name) ?? 'Session';
  }

  /// 关键词高亮（大小写不敏感）。
  List<TextSpan> _highlightSpans(
    BuildContext context,
    String text,
    String query,
    TextStyle base,
  ) {
    if (query.isEmpty) return [TextSpan(text: text, style: base)];
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        if (start < text.length) {
          spans.add(TextSpan(text: text.substring(start), style: base));
        }
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx), style: base));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: base.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ));
      start = idx + q.length;
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final q = widget.query.trim();
    final qLower = q.toLowerCase();

    final nameMatches = widget.sessions
        .where((s) => s.name.toLowerCase().contains(qLower))
        .toList();

    if (_loading && _hubLoading && nameMatches.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    final byChannel = <String, List<MessageSearchResult>>{};
    for (final r in _results) {
      byChannel.putIfAbsent(r.message.channelId ?? '', () => []).add(r);
    }

    if (!_loading &&
        !_hubLoading &&
        nameMatches.isEmpty &&
        byChannel.isEmpty &&
        _hubHits.isEmpty) {
      return Center(
        child: Text(
          l10n.home_searchNoResults,
          style: TextStyle(fontSize: 14, color: Colors.grey[500]),
        ),
      );
    }

    final children = <Widget>[];

    if (nameMatches.isNotEmpty) {
      children.add(_sectionHeader(l10n.chat_sessions));
      for (final s in nameMatches) {
        children.add(_nameMatchTile(context, s));
      }
    }

    // 折叠组里的会话（只读）：本机没有副本，所以是单独一段，带来源角标。
    if (_hubLoading) {
      children.add(const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ));
    } else if (_hubHits.isNotEmpty) {
      children.add(_sectionHeader(l10n.sessionSearchFoldedSection));
      for (final hit in _hubHits) {
        children.add(_hubHitTile(context, l10n, hit));
      }
    }

    if (_loading) {
      children.add(const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ));
    } else if (byChannel.isNotEmpty) {
      children.add(_sectionHeader(l10n.chat_messageResults));
      for (final entry in byChannel.entries) {
        children.addAll(_messageGroupTiles(context, l10n, entry.value));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: children,
    );
  }

  /// 主机上折叠组里的命中：只读记录，点开是那份记录（工作流进运行视图、
  /// 群聊进群聊视角）。
  Widget _hubHitTile(
    BuildContext context,
    AppLocalizations l10n,
    SessionSearchHit hit,
  ) {
    final target = _target;
    return ListTile(
      dense: true,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.lock_outline, size: 18, color: Colors.grey),
      ),
      title: Text(
        hit.title.isEmpty ? hit.sessionId : hit.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hit.snippet == null ? null : Text(hit.snippet!),
      trailing: Chip(
        label: Text(sessionSearchHitBadge(l10n, hit)),
        visualDensity: VisualDensity.compact,
      ),
      onTap: target == null
          ? null
          : () => openSessionSearchHit(
                context,
                peerId: target.peerId,
                hit: hit,
                client: widget.hubClient,
              ),
      // 工作流命中现在默认打开节点会话，「查看运行」留作长按的次级入口。
      onLongPress: target == null ||
              hit.origin.kind != 'flow' ||
              hit.origin.runId.isEmpty
          ? null
          : () => showFlowRunActions(
                context,
                peerId: target.peerId,
                runId: hit.origin.runId,
                title: hit.title.isEmpty ? hit.sessionId : hit.title,
              ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey[600],
        ),
      ),
    );
  }

  Widget _nameMatchTile(BuildContext context, Channel session) {
    return ListTile(
      dense: true,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _isGroupMode
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).primaryColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Icon(
          _isGroupMode ? Icons.group : Icons.chat_bubble_outline,
          size: 18,
          color:
              _isGroupMode ? AppColors.primary : Theme.of(context).primaryColor,
        ),
      ),
      title: Text(
        _sessionLabel(session),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        closePanelRoute(context);
        widget.onSwitchSession(session.id);
      },
    );
  }

  List<Widget> _messageGroupTiles(
    BuildContext context,
    AppLocalizations l10n,
    List<MessageSearchResult> results,
  ) {
    final channelId = results.first.message.channelId;
    final session = widget.sessions.where((s) => s.id == channelId).firstOrNull;
    final label =
        session != null ? _sessionLabel(session) : results.first.channelName;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              l10n.chat_messageMatchesCount(results.length),
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
      for (final r in results)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 16, right: 16),
          leading: const Icon(Icons.subject, size: 18, color: Colors.grey),
          title: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: _highlightSpans(
                context,
                r.message.content,
                widget.query.trim(),
                TextStyle(
                    fontSize: 13.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          onTap: () {
            closePanelRoute(context);
            widget.onLocateMessage(r.message, r.message.channelId);
          },
        ),
    ];
  }
}
