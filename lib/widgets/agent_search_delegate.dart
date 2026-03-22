import 'package:flutter/material.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_database_service.dart';
import '../services/message_search_service.dart';

/// Describes a search result selection so the caller can navigate using its own
/// standard flow (mark-as-read, resolve active channel, etc.).
class SearchSelection {
  final Agent? agent;
  final Channel? channel;
  final String? messageChannelId;
  final String? messageChannelName;
  final String? highlightMessageId;

  const SearchSelection({
    this.agent,
    this.channel,
    this.messageChannelId,
    this.messageChannelName,
    this.highlightMessageId,
  });
}

/// Global search delegate - searches agents, channels, and chat messages
class AgentSearchDelegate extends SearchDelegate<Agent?> {
  final List<Agent> agents;
  final LocalDatabaseService databaseService;
  final MessageSearchService messageSearchService;

  /// Called when the user taps a search result. The caller is responsible for
  /// navigating to the chat screen using its standard flow.
  final void Function(SearchSelection selection)? onResultSelected;

  AgentSearchDelegate({
    required this.agents,
    required this.databaseService,
    required this.messageSearchService,
    this.onResultSelected,
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
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchResults(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Search agents, groups, and messages',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }
    return _buildSearchResults(context);
  }

  Widget _buildSearchResults(BuildContext context) {
    if (query.isEmpty) {
      return const SizedBox.shrink();
    }

    // Filter agents locally
    final agentResults = agents.where((agent) {
      return agent.name.toLowerCase().contains(query.toLowerCase()) ||
          (agent.type?.toLowerCase().contains(query.toLowerCase()) ?? false) ||
          (agent.description?.toLowerCase().contains(query.toLowerCase()) ??
              false);
    }).toList();

    // Fetch channels and messages asynchronously
    return FutureBuilder<_GlobalSearchResults>(
      future: _performSearch(query),
      builder: (context, snapshot) {
        final channelResults = snapshot.data?.channels ?? [];
        final messageResults = snapshot.data?.messages ?? [];

        final hasAgents = agentResults.isNotEmpty;
        final hasChannels = channelResults.isNotEmpty;
        final hasMessages = messageResults.isNotEmpty;

        if (!hasAgents && !hasChannels && !hasMessages) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
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

        return ListView(
          children: [
            // Agent results section
            if (hasAgents) ...[
              _buildSectionHeader(context, 'Agents', agentResults.length),
              ...agentResults.map((agent) => _buildAgentTile(context, agent)),
            ],
            // Channel/group results section
            if (hasChannels) ...[
              _buildSectionHeader(context, 'Groups', channelResults.length),
              ...channelResults
                  .map((channel) => _buildChannelTile(context, channel)),
            ],
            // Message results section
            if (hasMessages) ...[
              _buildSectionHeader(
                  context, 'Chat Messages', messageResults.length),
              ...messageResults
                  .map((result) => _buildMessageTile(context, result)),
            ],
          ],
        );
      },
    );
  }

  Future<_GlobalSearchResults> _performSearch(String searchQuery) async {
    final channels = await _searchChannels(searchQuery);
    final messages = await messageSearchService.searchMessages(
      query: searchQuery,
      limit: 20,
    );
    return _GlobalSearchResults(channels: channels, messages: messages);
  }

  Future<List<Channel>> _searchChannels(String searchQuery) async {
    try {
      final allChannels = await databaseService.getAllChannels();
      return allChannels.where((channel) {
        return channel.name
                .toLowerCase()
                .contains(searchQuery.toLowerCase()) ||
            (channel.description
                    ?.toLowerCase()
                    .contains(searchQuery.toLowerCase()) ??
                false);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Widget _buildSectionHeader(BuildContext context, String title, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.grey[50],
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(width: 8),
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

  Widget _buildAgentTile(BuildContext context, Agent agent) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: agent.avatar.length <= 2
            ? Text(agent.avatar, style: const TextStyle(fontSize: 20))
            : ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  agent.avatar,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Text(
                      agent.name.isNotEmpty ? agent.name[0] : 'A',
                      style: const TextStyle(fontSize: 20),
                    );
                  },
                ),
              ),
      ),
      title: Text(agent.name),
      subtitle: Text(agent.description ?? agent.type ?? 'AI Agent'),
      onTap: () {
        close(context, agent);
        onResultSelected?.call(SearchSelection(agent: agent));
      },
    );
  }

  Widget _buildChannelTile(BuildContext context, Channel channel) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.blue[50],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(
          channel.isGroup ? Icons.group : Icons.chat_bubble_outline,
          color: Colors.blue[700],
          size: 20,
        ),
      ),
      title: Text(channel.name),
      subtitle: Text(
        channel.description ?? (channel.isGroup ? 'Group' : 'Chat'),
      ),
      onTap: () {
        close(context, null);
        onResultSelected?.call(SearchSelection(channel: channel));
      },
    );
  }

  Widget _buildMessageTile(BuildContext context, MessageSearchResult result) {
    final message = result.message;
    final isMyMessage = message.from.type == 'user';

    return InkWell(
      onTap: () {
        close(context, null);
        onResultSelected?.call(SearchSelection(
          messageChannelId: message.channelId,
          messageChannelName: result.channelName,
          highlightMessageId: message.id,
        ));
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
                // Channel name tag
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    result.channelName.isNotEmpty
                        ? result.channelName
                        : 'Unknown',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ),
                const SizedBox(width: 8),
                // Sender
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isMyMessage
                        ? Theme.of(context).primaryColor.withOpacity(0.15)
                        : Colors.grey[200],
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    message.senderName.isNotEmpty
                        ? message.senderName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: isMyMessage
                          ? Theme.of(context).primaryColor
                          : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: isMyMessage
                        ? Theme.of(context).primaryColor
                        : Colors.grey[800],
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTime(message.timestampMs),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _buildHighlightedContent(context, message.content),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedContent(BuildContext context, String content) {
    final baseStyle = TextStyle(color: Colors.grey[800], fontSize: 13);
    if (query.isEmpty) {
      return Text(content,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: baseStyle);
    }

    // Collapse all whitespace (newlines, tabs, etc.) into single spaces so
    // the match is always visible in the snippet.
    final flat = content.replaceAll(RegExp(r'\s+'), ' ');
    final lowerFlat = flat.toLowerCase();
    final lowerQuery = query.toLowerCase();

    final matchIndex = lowerFlat.indexOf(lowerQuery);
    if (matchIndex == -1) {
      return Text(flat,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: baseStyle);
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
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
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

class _GlobalSearchResults {
  final List<Channel> channels;
  final List<MessageSearchResult> messages;

  _GlobalSearchResults({required this.channels, required this.messages});
}
