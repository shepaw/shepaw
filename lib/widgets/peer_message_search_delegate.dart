import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/peer_message.dart';
import '../peer/services/peer_storage_service.dart';
import 'shepaw_search_page.dart';

/// Peer 设备聊天消息搜索 delegate
class PeerMessageSearchDelegate extends SearchDelegate<String> {
  final String peerId;
  final String peerName;
  final PeerStorageService storageService;
  final void Function(PeerMessage message)? onResultTap;

  PeerMessageSearchDelegate({
    required this.peerId,
    required this.peerName,
    required this.storageService,
    this.onResultTap,
  }) : super(
          searchFieldStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
          ),
        );

  @override
  List<Widget>? buildActions(BuildContext context) => null;

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => popShepawSearch(context, ''),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchResults(context, query);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) {
      return _buildEmptyHint(context);
    }
    return _buildSearchResults(context, query);
  }

  Widget _buildEmptyHint(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            l10n.peerChat_searchInConversation(peerName),
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context, String searchQuery) {
    return FutureBuilder<List<PeerMessageSearchResult>>(
      future: storageService.searchMessages(
        query: searchQuery,
        peerId: peerId,
        limit: 50,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Search error: ${snapshot.error}',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          );
        }

        final results = snapshot.data ?? [];
        if (results.isEmpty) {
          final l10n = AppLocalizations.of(context);
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  l10n.home_searchNoResults,
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            return _buildSearchResultTile(context, results[index]);
          },
        );
      },
    );
  }

  Widget _buildSearchResultTile(
    BuildContext context,
    PeerMessageSearchResult result,
  ) {
    final message = result.message;

    return InkWell(
      onTap: () {
        onResultTap?.call(message);
        popShepawSearch(context, message.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            const SizedBox(height: 4),
            _buildHighlightedContent(context, message.content),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedContent(BuildContext context, String content) {
    final baseStyle = TextStyle(color: Colors.grey[800], fontSize: 13);
    if (query.isEmpty) {
      return Text(
        content,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    final flat = content.replaceAll(RegExp(r'\s+'), ' ');
    final lowerFlat = flat.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerFlat.indexOf(lowerQuery);
    if (matchIndex == -1) {
      return Text(
        flat,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    const windowSize = 40;
    final snippetStart = matchIndex > windowSize ? matchIndex - windowSize : 0;
    final matchEnd = matchIndex + query.length;
    final snippetEnd = (matchEnd + windowSize).clamp(0, flat.length);
    final before = flat.substring(snippetStart, matchIndex);
    final match = flat.substring(matchIndex, matchEnd);
    final after = flat.substring(matchEnd, snippetEnd);

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: baseStyle,
        children: [
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
        ],
      ),
    );
  }

  String _formatTime(int timestampMs) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inDays == 0) {
      return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[dateTime.weekday - 1];
    } else {
      return '${dateTime.month}/${dateTime.day}';
    }
  }
}
