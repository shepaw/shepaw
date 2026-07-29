import 'agent.dart';
import 'channel.dart';
import '../peer/models/paired_peer.dart';

/// Tagged union for a unified conversation list item (agent, group, or peer).
class ConversationListItem {
  final Agent? agent;
  final Channel? group;
  final PairedPeer? peer;
  final DateTime? lastMessageTime;

  ConversationListItem.agent(this.agent, this.lastMessageTime)
      : group = null,
        peer = null;

  ConversationListItem.group(this.group, this.lastMessageTime)
      : agent = null,
        peer = null;

  ConversationListItem.peer(this.peer, this.lastMessageTime)
      : agent = null,
        group = null;

  bool get isAgent => agent != null;
  bool get isGroup => group != null;
  bool get isPeer => peer != null;
}

/// A sortable block in the home conversation list (one row each).
class ConversationListBlock {
  final DateTime? sortTime;
  final bool isShe;
  final List<ConversationListItem> items;

  ConversationListBlock.standalone(ConversationListItem item, {this.isShe = false})
      : sortTime = item.lastMessageTime,
        items = [item];
}
