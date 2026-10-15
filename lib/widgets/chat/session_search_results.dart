import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../services/message_search_service.dart';
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
/// 用 StatefulWidget 是为了持有防抖状态：消息搜索是 `content LIKE '%q%'`
/// 全表扫（命中不了索引）且带几百个 channelId，每敲一个字符查一次很贵。
class SessionSearchResults extends StatefulWidget {
  const SessionSearchResults({
    super.key,
    required this.query,
    required this.sessions,
    required this.searchService,
    required this.onSwitchSession,
    required this.onLocateMessage,
    this.groupChannel,
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

  @override
  State<SessionSearchResults> createState() => _SessionSearchResultsState();
}

class _SessionSearchResultsState extends State<SessionSearchResults> {
  /// 输入防抖窗口。
  static const _searchDebounce = Duration(milliseconds: 250);

  /// 本次实际要查的关键词；被更新的击键覆盖后，旧的等待直接作废。
  String _latestQuery = '';

  bool get _isGroupMode => widget.groupChannel != null;

  Future<List<MessageSearchResult>> _debouncedSearch(String q) async {
    _latestQuery = q;
    await Future<void>.delayed(_searchDebounce);
    if (_latestQuery != q) return const <MessageSearchResult>[];
    return widget.searchService.searchMessages(
      query: q,
      channelIds: [for (final s in widget.sessions) s.id],
      limit: 100,
    );
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

    return FutureBuilder<List<MessageSearchResult>>(
      // 查询变化时重建 Future，旧查询的迟到结果直接丢弃。
      key: ValueKey(q),
      future: _debouncedSearch(q),
      builder: (context, snapshot) {
        final results = snapshot.data ?? const <MessageSearchResult>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          );
        }

        final byChannel = <String, List<MessageSearchResult>>{};
        for (final r in results) {
          byChannel
              .putIfAbsent(r.message.channelId ?? '', () => [])
              .add(r);
        }

        if (nameMatches.isEmpty && byChannel.isEmpty) {
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

        if (byChannel.isNotEmpty) {
          children.add(_sectionHeader(l10n.chat_messageResults));
          for (final entry in byChannel.entries) {
            children.addAll(_messageGroupTiles(context, l10n, entry.value));
          }
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: children,
        );
      },
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
          color: _isGroupMode ? AppColors.primary : Theme.of(context).primaryColor,
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
    final session =
        widget.sessions.where((s) => s.id == channelId).firstOrNull;
    final label = session != null ? _sessionLabel(session) : results.first.channelName;

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
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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
                TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
