import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/dispatch/she_relay_session_service.dart';

void main() {
  group('SheRelaySessionService helpers', () {
    test('relaySessionId is deterministic and unique per pair', () {
      final a = SheRelaySessionService.relaySessionId('she_ch_1', 'agent_1');
      final b = SheRelaySessionService.relaySessionId('she_ch_1', 'agent_1');
      final c = SheRelaySessionService.relaySessionId('she_ch_1', 'agent_2');
      final d = SheRelaySessionService.relaySessionId('she_ch_2', 'agent_1');

      expect(a, b);
      expect(a, 'shed_she_ch_1__agent_1');
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('relaySessionTitle marks the session as She-bound', () {
      expect(SheRelaySessionService.relaySessionTitle('codebuddy'),
          'She · codebuddy');
    });

    test('Channel.isSheBoundSession', () {
      final bound = Channel(
        id: 'shed_she_ch_1__agent_1',
        name: 'She · codebuddy',
        type: 'dm',
        members: const [],
        sourceSheChannelId: 'she_ch_1',
      );
      final personal = Channel(
        id: 'dm_user_agent',
        name: 'Chat',
        type: 'dm',
        members: const [],
      );
      final groupBound = Channel(
        id: 'gmd_group_1__agent_1',
        name: 'Group · Team',
        type: 'dm',
        members: const [],
        sourceGroupChannelId: 'group_1',
      );
      final group = Channel(
        id: 'group_1',
        name: 'Team',
        type: 'group',
        members: const [],
        sourceSheChannelId: 'should_ignore',
      );

      expect(bound.isSheBoundSession, isTrue);
      expect(personal.isSheBoundSession, isFalse);
      expect(groupBound.isSheBoundSession, isFalse);
      // 群聊频道本身不算 She 绑定会话（必须是 DM）
      expect(group.isSheBoundSession, isFalse);
    });

    test('sourceSheChannelId survives copyWith and json roundtrip', () {
      final bound = Channel(
        id: 'shed_she_ch_1__agent_1',
        name: 'She · codebuddy',
        type: 'dm',
        members: const [],
        sourceSheChannelId: 'she_ch_1',
      );

      expect(bound.copyWith(name: 'renamed').sourceSheChannelId, 'she_ch_1');

      final restored = Channel.fromJson(bound.toJson());
      expect(restored.sourceSheChannelId, 'she_ch_1');
      expect(restored.isSheBoundSession, isTrue);
    });
  });
}
