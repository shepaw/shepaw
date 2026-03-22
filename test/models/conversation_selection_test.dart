import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/conversation_selection.dart';

void main() {
  group('ConversationSelection Tests', () {
    test('should create with all null fields', () {
      const selection = ConversationSelection();

      expect(selection.agentId, isNull);
      expect(selection.agentName, isNull);
      expect(selection.agentAvatar, isNull);
      expect(selection.channelId, isNull);
      expect(selection.groupFamilyId, isNull);
      expect(selection.highlightMessageId, isNull);
    });

    test('should create with all fields set', () {
      const selection = ConversationSelection(
        agentId: 'agent-1',
        agentName: 'Bot',
        agentAvatar: '🤖',
        channelId: 'ch-1',
        groupFamilyId: 'group-1',
        highlightMessageId: 'msg-1',
      );

      expect(selection.agentId, 'agent-1');
      expect(selection.agentName, 'Bot');
      expect(selection.agentAvatar, '🤖');
      expect(selection.channelId, 'ch-1');
      expect(selection.groupFamilyId, 'group-1');
      expect(selection.highlightMessageId, 'msg-1');
    });

    group('key', () {
      test('should use channelId as base when available', () {
        const selection = ConversationSelection(
          agentId: 'agent-1',
          channelId: 'ch-1',
        );
        expect(selection.key, 'ch-1');
      });

      test('should use agentId as base when no channelId', () {
        const selection = ConversationSelection(agentId: 'agent-1');
        expect(selection.key, 'agent-1');
      });

      test('should return empty string when no channelId or agentId', () {
        const selection = ConversationSelection();
        expect(selection.key, '');
      });

      test('should include highlightMessageId in key', () {
        const selection = ConversationSelection(
          channelId: 'ch-1',
          highlightMessageId: 'msg-5',
        );
        expect(selection.key, 'ch-1#msg-5');
      });

      test('should not include hash when no highlightMessageId', () {
        const selection = ConversationSelection(channelId: 'ch-1');
        expect(selection.key, 'ch-1');
        expect(selection.key.contains('#'), false);
      });
    });

    group('equality', () {
      test('should be equal when agentId, channelId, groupFamilyId match', () {
        const a = ConversationSelection(
          agentId: 'agent-1',
          channelId: 'ch-1',
          groupFamilyId: 'g-1',
          agentName: 'Bot A',
        );
        const b = ConversationSelection(
          agentId: 'agent-1',
          channelId: 'ch-1',
          groupFamilyId: 'g-1',
          agentName: 'Bot B', // different name, should still be equal
        );

        expect(a == b, true);
        expect(a.hashCode, b.hashCode);
      });

      test('should not be equal when agentId differs', () {
        const a = ConversationSelection(agentId: 'agent-1', channelId: 'ch-1');
        const b = ConversationSelection(agentId: 'agent-2', channelId: 'ch-1');

        expect(a == b, false);
      });

      test('should not be equal when channelId differs', () {
        const a = ConversationSelection(agentId: 'agent-1', channelId: 'ch-1');
        const b = ConversationSelection(agentId: 'agent-1', channelId: 'ch-2');

        expect(a == b, false);
      });

      test('should not be equal when groupFamilyId differs', () {
        const a = ConversationSelection(
          agentId: 'agent-1',
          groupFamilyId: 'g-1',
        );
        const b = ConversationSelection(
          agentId: 'agent-1',
          groupFamilyId: 'g-2',
        );

        expect(a == b, false);
      });

      test('highlightMessageId should not affect equality', () {
        const a = ConversationSelection(
          channelId: 'ch-1',
          highlightMessageId: 'msg-1',
        );
        const b = ConversationSelection(
          channelId: 'ch-1',
          highlightMessageId: 'msg-2',
        );

        expect(a == b, true);
      });

      test('identical objects should be equal', () {
        const selection = ConversationSelection(agentId: 'a');
        expect(selection == selection, true);
      });

      test('different types should not be equal', () {
        const selection = ConversationSelection(agentId: 'a');
        // ignore: unrelated_type_equality_checks
        expect(selection == 'not a selection', false);
      });
    });

    group('hashCode', () {
      test('should be consistent for equal objects', () {
        const a = ConversationSelection(
          agentId: 'agent-1',
          channelId: 'ch-1',
          groupFamilyId: 'g-1',
        );
        const b = ConversationSelection(
          agentId: 'agent-1',
          channelId: 'ch-1',
          groupFamilyId: 'g-1',
        );

        expect(a.hashCode, b.hashCode);
      });
    });
  });
}
