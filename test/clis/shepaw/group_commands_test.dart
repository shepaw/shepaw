import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/group/group_commands.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/group/group_admin_gate.dart';
import 'package:shepaw/services/group/group_management_service.dart';
import 'package:shepaw/services/she_service.dart';

Channel _group({
  required String adminId,
  List<String> memberIds = const [],
}) {
  return Channel(
    id: 'group_1',
    name: 'Team',
    type: 'group',
    members: [
      ChannelMember(id: 'user', type: 'user', role: 'member', joinedAt: 1),
      ChannelMember(id: adminId, type: 'agent', role: 'admin', joinedAt: 1),
      ...memberIds.map(
        (id) => ChannelMember(id: id, type: 'agent', role: 'member', joinedAt: 1),
      ),
    ],
  );
}

void main() {
  group('GroupManagementService helpers', () {
    test('resolveChannelId prefers --channel over channel_id', () {
      expect(
        GroupManagementService.resolveChannelId({
          'channel': 'g1',
          'channel_id': 'injected',
        }),
        'g1',
      );
      expect(
        GroupManagementService.resolveChannelId({'channel_id': 'injected'}),
        'injected',
      );
      expect(GroupManagementService.resolveChannelId({}), isNull);
    });

    test('parseAgentRefs splits commas and whitespace', () {
      expect(
        GroupManagementService.parseAgentRefs('Coder, Researcher，She'),
        ['Coder', 'Researcher', 'She'],
      );
      expect(GroupManagementService.parseAgentRefs('  '), isEmpty);
      expect(GroupManagementService.parseAgentRefs(null), isEmpty);
    });
  });

  group('GroupAdminGate', () {
    test('allows the admin and denies non-admin members', () {
      final channel = _group(
        adminId: SheService.sheId,
        memberIds: const ['coder-1'],
      );
      expect(
        GroupAdminGate.denyReason(
          channel: channel,
          channelId: channel.id,
          actorId: SheService.sheId,
        ),
        isNull,
      );
      expect(GroupAdminGate.canMutate(channel: channel, actorId: SheService.sheId), isTrue);

      final denied = GroupAdminGate.denyReason(
        channel: channel,
        channelId: channel.id,
        actorId: 'coder-1',
      );
      expect(denied, contains('Permission denied'));
      expect(denied, contains('not the admin'));
      expect(GroupAdminGate.canMutate(channel: channel, actorId: 'coder-1'), isFalse);
    });

    test('denies missing channel, non-group, and empty actor', () {
      expect(
        GroupAdminGate.denyReason(
          channel: null,
          channelId: 'missing',
          actorId: SheService.sheId,
        ),
        contains('Channel not found'),
      );

      final dm = Channel(
        id: 'dm_1',
        name: 'DM',
        type: 'dm',
        members: [
          ChannelMember(id: SheService.sheId, type: 'agent', role: 'admin', joinedAt: 1),
        ],
      );
      expect(
        GroupAdminGate.denyReason(
          channel: dm,
          channelId: dm.id,
          actorId: SheService.sheId,
        ),
        contains('Not a group channel'),
      );

      final group = _group(adminId: SheService.sheId);
      expect(
        GroupAdminGate.denyReason(
          channel: group,
          channelId: group.id,
          actorId: '',
        ),
        contains('Permission denied'),
      );
    });
  });

  group('group CLI command validation', () {
    test('create requires --name', () async {
      final result = await GroupCreateCommand().execute({});
      expect(result['error'], contains('--name'));
    });

    test('add requires --channel and --agent', () async {
      final missingChannel = await GroupAddCommand().execute({'agent': 'Coder'});
      expect(missingChannel['error'], contains('--channel'));

      final missingAgent = await GroupAddCommand().execute({
        'channel': 'group_1',
      });
      expect(missingAgent['error'], contains('--agent'));
    });

    test('kick requires --channel and --agent', () async {
      final missingChannel =
          await GroupKickCommand().execute({'agent': 'Coder'});
      expect(missingChannel['error'], contains('--channel'));

      final missingAgent = await GroupKickCommand().execute({
        'channel': 'group_1',
      });
      expect(missingAgent['error'], contains('--agent'));
    });

    test('rename requires --channel and --name', () async {
      final missingChannel =
          await GroupRenameCommand().execute({'name': 'New'});
      expect(missingChannel['error'], contains('--channel'));

      final missingName = await GroupRenameCommand().execute({
        'channel': 'group_1',
      });
      expect(missingName['error'], contains('--name'));
    });
  });
}
