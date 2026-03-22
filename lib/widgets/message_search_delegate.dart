import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/message_search_service.dart';
import '../utils/message_utils.dart';

/// Message search delegate - 支持跨会话搜索并标记来源
class MessageSearchDelegate extends SearchDelegate<String> {
  final MessageSearchService searchService;
  final String? channelId;
  final List<String>? channelIds;
  final Function(Message message, String? channelId)? onResultTap;

  MessageSearchDelegate({
    required this.searchService,
    this.channelId,
    this.channelIds,
    this.onResultTap,
  });

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, '');
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchResults(context, query);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) {
      return _buildRecentSearches(context);
    }
    return _buildSearchResults(context, query);
  }

  /// Build search results
  Widget _buildSearchResults(BuildContext context, String searchQuery) {
    return FutureBuilder<List<MessageSearchResult>>(
      future: searchService.searchMessages(
        query: searchQuery,
        channelId: channelId,
        channelIds: channelIds,
        limit: 50,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Search error: ${snapshot.error}',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        final results = snapshot.data ?? [];

        if (results.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  'No results found',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        // 按会话分组显示
        final groupedByChannel = <String, List<MessageSearchResult>>{};
        for (final result in results) {
          final key = result.message.channelId ?? '';
          groupedByChannel.putIfAbsent(key, () => []).add(result);
        }

        final channelKeys = groupedByChannel.keys.toList();

        return ListView.builder(
          itemCount: results.length + channelKeys.length,
          itemBuilder: (context, index) {
            int offset = 0;
            for (final channelKey in channelKeys) {
              final channelResults = groupedByChannel[channelKey]!;
              final channelName = channelResults.first.channelName;

              // Channel header
              if (index == offset) {
                return _buildChannelHeader(context, channelName, channelResults.length);
              }
              offset++;

              // Messages in this channel
              if (index < offset + channelResults.length) {
                final result = channelResults[index - offset];
                return _buildSearchResultTile(context, result);
              }
              offset += channelResults.length;
            }

            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  /// Build channel group header
  Widget _buildChannelHeader(BuildContext context, String channelName, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.grey[50],
      child: Row(
        children: [
          Icon(Icons.chat_bubble_outline, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              channelName.isNotEmpty ? channelName : 'Unknown',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build search result tile
  Widget _buildSearchResultTile(BuildContext context, MessageSearchResult result) {
    final message = result.message;
    final isMyMessage = message.from.type == 'user';

    return InkWell(
      onTap: () {
        onResultTap?.call(message, message.channelId);
        close(context, message.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Sender avatar
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isMyMessage
                        ? Theme.of(context).primaryColor.withOpacity(0.15)
                        : Colors.grey[200],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    message.senderName.isNotEmpty
                        ? message.senderName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isMyMessage
                          ? Theme.of(context).primaryColor
                          : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isMyMessage ? Theme.of(context).primaryColor : Colors.grey[800],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  MessageUtils.formatMessageTime(message),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: _buildHighlightedContent(context, message.content),
            ),
          ],
        ),
      ),
    );
  }

  /// Build content with search keyword highlighted
  Widget _buildHighlightedContent(BuildContext context, String content) {
    final baseStyle = TextStyle(color: Colors.grey[800], fontSize: 13);
    if (query.isEmpty) {
      return Text(content,
          maxLines: 3, overflow: TextOverflow.ellipsis, style: baseStyle);
    }

    // Collapse all whitespace (newlines, tabs, etc.) into single spaces so
    // the match is always visible in the snippet.
    final flat = content.replaceAll(RegExp(r'\s+'), ' ');
    final lowerFlat = flat.toLowerCase();
    final lowerQuery = query.toLowerCase();

    final matchIndex = lowerFlat.indexOf(lowerQuery);
    if (matchIndex == -1) {
      return Text(flat,
          maxLines: 3, overflow: TextOverflow.ellipsis, style: baseStyle);
    }

    // Extract a window of ~40 chars before and after the first match.
    const windowSize = 40;
    final snippetStart = matchIndex > windowSize ? matchIndex - windowSize : 0;
    final matchEnd = matchIndex + query.length;
    final snippetEnd = (matchEnd + windowSize).clamp(0, flat.length);

    final before = flat.substring(snippetStart, matchIndex);
    final match = flat.substring(matchIndex, matchEnd);
    final after = flat.substring(matchEnd, snippetEnd);

    final spans = <TextSpan>[
      if (snippetStart > 0) const TextSpan(text: '...'),
      TextSpan(text: before),
      TextSpan(
        text: match,
        style: TextStyle(
          backgroundColor: Colors.yellow[200],
          fontWeight: FontWeight.w600,
        ),
      ),
      TextSpan(text: after),
      if (snippetEnd < flat.length) const TextSpan(text: '...'),
    ];

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }

  /// Build recent searches
  Widget _buildRecentSearches(BuildContext context) {
    final isScoped = channelId != null || (channelIds != null && channelIds!.isNotEmpty);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            isScoped
                ? 'Search in this conversation'
                : 'Search all messages',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            isScoped
                ? 'Search messages with this agent'
                : 'Search across all conversations',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
