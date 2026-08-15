import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/conversation_list_controller.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/models/paired_peer.dart';

Agent _agent({
  required String id,
  required String name,
  bool isShe = false,
  String? sourcePeerId,
  bool hiddenOnThisApp = false,
}) {
  return Agent(
    id: id,
    name: name,
    avatar: 'A',
    provider: const AgentProvider(name: 'local', platform: 'local', type: 'local'),
    status: const AgentStatus(state: 'online'),
    metadata: {
      if (isShe) 'is_she': true,
      if (sourcePeerId != null) 'source_peer_id': sourcePeerId,
      if (hiddenOnThisApp) 'hidden_on_this_app': true,
    },
  );
}

PairedPeer _peer(String id, String name, {int pairedAt = 1000}) {
  return PairedPeer(
    id: id,
    deviceName: name,
    deviceId: 'device-$id',
    publicKey: Uint8List(32),
    fingerprint: 'fp-$id',
    pairedAt: pairedAt,
  );
}

Channel _group(String id, String name) {
  return Channel(
    id: id,
    name: name,
    type: 'group',
    members: const [],
  );
}

void main() {
  group('ConversationListController.buildSortedConversations', () {
    test('pins She agent above newer conversations', () {
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: [
          _agent(id: 'a1', name: 'Later', isShe: false),
          _agent(id: 'she', name: 'She', isShe: true),
        ],
        groupChannels: const [],
        pairedPeers: const [],
        searchQuery: '',
        latestMessages: {
          'a1': {'created_at': '2026-07-11T12:00:00.000Z'},
          'she': {'created_at': '2026-07-01T12:00:00.000Z'},
        },
        groupLatestMessages: const {},
        peerLatestTime: const {},
      );

      expect(entries.first.agent?.id, 'she');
      expect(entries[1].agent?.id, 'a1');
    });

    test('sorts peer agents and devices independently by activation time', () {
      final peer = _peer('p1', 'Phone');
      final child = _agent(id: 'pa', name: 'PeerAgent', sourcePeerId: 'p1');
      final local = _agent(id: 'local', name: 'Local');

      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: [child, local],
        groupChannels: const [],
        pairedPeers: [peer],
        searchQuery: '',
        latestMessages: {
          'pa': {'created_at': '2026-07-11T12:00:00.000Z'},
          'local': {'created_at': '2026-07-10T12:00:00.000Z'},
        },
        groupLatestMessages: const {},
        peerLatestTime: {
          'p1': DateTime.parse('2026-07-09T12:00:00.000Z').millisecondsSinceEpoch,
        },
        deviceChatUiEnabled: true,
      );

      // Newest first: peer agent → local agent → device (no nesting).
      expect(entries.length, 3);
      expect(entries[0].agent?.id, 'pa');
      expect(entries[1].agent?.id, 'local');
      expect(entries[2].isPeer, isTrue);
      expect(entries[2].peer?.id, 'p1');
    });

    test('omits peer device rows when device chat UI is disabled', () {
      final peer = _peer('p1', 'Phone');
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: const [],
        groupChannels: const [],
        pairedPeers: [peer],
        searchQuery: '',
        latestMessages: const {},
        groupLatestMessages: const {},
        peerLatestTime: const {
          'p1': 1700000000000,
        },
        deviceChatUiEnabled: false,
      );

      expect(entries, isEmpty);
    });

    test('includes matching groups by name', () {
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: const [],
        groupChannels: [
          _group('g1', 'Alpha Team'),
          _group('g2', 'Beta'),
        ],
        pairedPeers: const [],
        searchQuery: 'alpha',
        latestMessages: const {},
        groupLatestMessages: {
          'g1': {'created_at': '2026-07-11T12:00:00.000Z'},
        },
        peerLatestTime: const {},
      );

      expect(entries.length, 1);
      expect(entries.first.group?.id, 'g1');
    });

    test('draft updatedAt bumps conversation above older messages', () {
      final draftTime = DateTime.parse('2026-07-12T12:00:00.000Z');
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: [
          _agent(id: 'old', name: 'Old'),
          _agent(id: 'drafty', name: 'Drafty'),
        ],
        groupChannels: const [],
        pairedPeers: const [],
        searchQuery: '',
        latestMessages: {
          'old': {'created_at': '2026-07-11T12:00:00.000Z'},
          'drafty': {'created_at': '2026-07-01T12:00:00.000Z'},
        },
        groupLatestMessages: const {},
        peerLatestTime: const {},
        draftUpdatedAtForAgent: (id) => id == 'drafty' ? draftTime : null,
      );

      expect(entries.first.agent?.id, 'drafty');
      expect(entries[1].agent?.id, 'old');
    });

    test('opening without messages or draft does not bump sort time', () {
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: [
          _agent(id: 'chatted', name: 'Chatted'),
          _agent(id: 'peeked', name: 'Peeked'),
        ],
        groupChannels: const [],
        pairedPeers: const [],
        searchQuery: '',
        latestMessages: {
          'chatted': {'created_at': '2026-07-11T12:00:00.000Z'},
          'peeked': null,
        },
        groupLatestMessages: const {},
        peerLatestTime: const {},
      );

      expect(entries.first.agent?.id, 'chatted');
      expect(entries[1].agent?.id, 'peeked');
    });

    test('older message time wins when neither has draft', () {
      // 消息时间晚于会话活跃时间时，仍以消息时间为准（max 语义）。
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: [
          _agent(id: 'a', name: 'A'),
          _agent(id: 'b', name: 'B'),
        ],
        groupChannels: const [],
        pairedPeers: const [],
        searchQuery: '',
        latestMessages: {
          'a': {'created_at': '2026-07-11T12:00:00.000Z'},
          'b': {'created_at': '2026-07-10T12:00:00.000Z'},
        },
        groupLatestMessages: const {},
        peerLatestTime: const {},
      );

      expect(entries.first.agent?.id, 'a');
      expect(entries[1].agent?.id, 'b');
    });

    test('empty new group without messages stays below chatted group', () {
      final entries = ConversationListController.buildSortedConversations(
        filteredAgents: const [],
        groupChannels: [
          _group('g-chatted', 'Chatted Group'),
          _group('g-fresh', 'Fresh Group'),
        ],
        pairedPeers: const [],
        searchQuery: '',
        latestMessages: const {},
        groupLatestMessages: {
          'g-chatted': {'created_at': '2026-07-11T12:00:00.000Z'},
          'g-fresh': null,
        },
        peerLatestTime: const {},
      );

      expect(entries.first.group?.id, 'g-chatted');
      expect(entries[1].group?.id, 'g-fresh');
    });
  });

  group('ConversationListController.visibleOnThisApp', () {
    test('drops peer agents hidden on this app, keeps local agents', () {
      final visible = ConversationListController.visibleOnThisApp([
        _agent(id: 'local', name: 'Local'),
        _agent(id: 'shown', name: 'Shown', sourcePeerId: 'p1'),
        _agent(
          id: 'hidden',
          name: 'Hidden',
          sourcePeerId: 'p1',
          hiddenOnThisApp: true,
        ),
      ]);
      expect(visible.map((a) => a.id), ['local', 'shown']);
    });
  });
}
