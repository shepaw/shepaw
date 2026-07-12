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
        collapsedPeerIds: {},
      );

      expect(entries.first.agent?.id, 'she');
      expect(entries[1].agent?.id, 'a1');
    });

    test('nests peer agents under peer and hides them when collapsed', () {
      final peer = _peer('p1', 'Phone');
      final child = _agent(id: 'pa', name: 'PeerAgent', sourcePeerId: 'p1');
      final local = _agent(id: 'local', name: 'Local');

      final expanded = ConversationListController.buildSortedConversations(
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
        collapsedPeerIds: {},
      );

      expect(expanded[0].isPeer, isTrue);
      expect(expanded[1].agent?.id, 'pa');
      expect(expanded[2].agent?.id, 'local');

      final collapsed = ConversationListController.buildSortedConversations(
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
        collapsedPeerIds: {'p1'},
      );

      expect(collapsed.length, 2);
      expect(collapsed[0].isPeer, isTrue);
      expect(collapsed[1].agent?.id, 'local');
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
        collapsedPeerIds: {},
      );

      expect(entries.length, 1);
      expect(entries.first.group?.id, 'g1');
    });
  });
}
