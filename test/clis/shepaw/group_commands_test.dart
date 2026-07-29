import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/group/group_commands.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/group/group_management_service.dart';
import 'package:shepaw/services/she_service.dart';

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

  group('Channel admin check', () {
    test('isAdmin reflects member role', () {
      final channel = Channel(
        id: 'group_1',
        name: 'Team',
        type: 'group',
        members: [
          ChannelMember(
            id: 'user',
            type: 'user',
            role: 'member',
            joinedAt: 1,
          ),
          ChannelMember(
            id: SheService.sheId,
            type: 'agent',
            role: 'admin',
            joinedAt: 1,
          ),
          ChannelMember(
            id: 'coder-1',
            type: 'agent',
            role: 'member',
            joinedAt: 1,
          ),
        ],
      );
      expect(channel.isAdmin(SheService.sheId), isTrue);
      expect(channel.isAdmin('coder-1'), isFalse);
      expect(channel.adminAgentId, SheService.sheId);
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

    test('resolveChannelId used by add accepts channel_id injection', () {
      expect(
        GroupManagementService.resolveChannelId({'channel_id': 'group_x'}),
        'group_x',
      );
    });
  });
}
