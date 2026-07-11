import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_load_channel_planner.dart';
import 'package:shepaw/controllers/peer_device_label_resolver.dart';
import 'package:shepaw/models/channel.dart';

Channel _channel({
  required String id,
  required String name,
  required String type,
  List<ChannelMember> members = const [],
}) {
  return Channel(
    id: id,
    name: name,
    type: type,
    members: members,
    createdBy: 'u',
    createdAt: 1,
  );
}

void main() {
  group('ChatLoadChannelPlanner', () {
    test('decideChannel covers keep / initial / agent / abort', () {
      expect(
        ChatLoadChannelPlanner.decideChannel(
          currentChannelId: 'c1',
          initialChannelId: 'i',
          agentId: 'a',
        ),
        ChatLoadChannelAction.keepCurrent,
      );
      expect(
        ChatLoadChannelPlanner.decideChannel(
          currentChannelId: null,
          initialChannelId: 'i',
          agentId: 'a',
        ),
        ChatLoadChannelAction.useInitial,
      );
      expect(
        ChatLoadChannelPlanner.decideChannel(
          currentChannelId: null,
          initialChannelId: null,
          agentId: 'a',
        ),
        ChatLoadChannelAction.resolveFromAgent,
      );
      expect(
        ChatLoadChannelPlanner.decideChannel(
          currentChannelId: null,
          initialChannelId: null,
          agentId: null,
        ),
        ChatLoadChannelAction.abort,
      );
    });

    test('groupAgentMemberIds excludes user ids', () {
      final channel = _channel(
        id: 'g1',
        name: 'G',
        type: 'group',
        members: [
          ChannelMember(id: 'u', type: 'user', role: 'member', joinedAt: 1),
          ChannelMember(id: 'user', type: 'user', role: 'member', joinedAt: 1),
          ChannelMember(id: 'a1', type: 'agent', role: 'member', joinedAt: 1),
          ChannelMember(id: 'a2', type: 'agent', role: 'admin', joinedAt: 1),
        ],
      );
      expect(
        ChatLoadChannelPlanner.groupAgentMemberIds(channel, 'u'),
        ['a1', 'a2'],
      );
      expect(ChatLoadChannelPlanner.firstAgentMemberId(channel), 'a1');
    });
  });

  group('PeerDeviceLabelResolver', () {
    test('peerIdFromMembers and labelFromChannelName', () {
      expect(
        PeerDeviceLabelResolver.peerIdFromMembers([
          ChannelMember(id: 'a', type: 'agent', role: 'member', joinedAt: 1),
          ChannelMember(
            id: 'peer:dev-9',
            type: 'user',
            role: 'member',
            joinedAt: 1,
          ),
        ]),
        'dev-9',
      );
      expect(
        PeerDeviceLabelResolver.labelFromChannelName('Coder ← Pixel'),
        'Pixel',
      );
      expect(PeerDeviceLabelResolver.labelFromChannelName('Coder'), isNull);
    });

    test('hostInboundLabel prefers live peer name then channel suffix', () {
      final channel = _channel(
        id: 'peer__x__y',
        name: 'Bot ← FallbackPhone',
        type: 'dm',
        members: [
          ChannelMember(
            id: 'peer:p1',
            type: 'user',
            role: 'member',
            joinedAt: 1,
          ),
        ],
      );
      expect(
        PeerDeviceLabelResolver.hostInboundLabel(
          channel: channel,
          peers: [(id: 'p1', deviceName: 'LivePhone')],
        ),
        'LivePhone',
      );
      expect(
        PeerDeviceLabelResolver.hostInboundLabel(
          channel: channel,
          peers: const [],
        ),
        'FallbackPhone',
      );
    });

    test('clientAgentId and clientPeerAgentLabel', () {
      final channel = _channel(
        id: 'dm_1',
        name: 'DM',
        type: 'dm',
        members: [
          ChannelMember(id: 'agent-x', type: 'agent', role: 'member', joinedAt: 1),
        ],
      );
      expect(
        PeerDeviceLabelResolver.clientAgentId(
          channel: channel,
          fallbackAgentId: 'fallback',
        ),
        'agent-x',
      );
      expect(
        PeerDeviceLabelResolver.clientAgentId(
          channel: null,
          fallbackAgentId: 'fallback',
        ),
        'fallback',
      );

      expect(
        PeerDeviceLabelResolver.clientPeerAgentLabel(
          isPeerAgent: false,
          sourcePeerId: 'p1',
          sourcePeerNameSnapshot: 'Snap',
          peers: [(id: 'p1', deviceName: 'Live')],
        ),
        isNull,
      );
      expect(
        PeerDeviceLabelResolver.clientPeerAgentLabel(
          isPeerAgent: true,
          sourcePeerId: 'p1',
          sourcePeerNameSnapshot: 'Snap',
          peers: [(id: 'p1', deviceName: 'Live')],
        ),
        'Live',
      );
      expect(
        PeerDeviceLabelResolver.clientPeerAgentLabel(
          isPeerAgent: true,
          sourcePeerId: 'missing',
          sourcePeerNameSnapshot: 'Snap',
          peers: const [],
        ),
        'Snap',
      );
    });
  });
}
