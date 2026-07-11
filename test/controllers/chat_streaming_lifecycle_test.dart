import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_lifecycle_coordinator.dart';
import 'package:shepaw/controllers/chat_streaming_text.dart';
import 'package:shepaw/controllers/peer_approval_completer_resolver.dart';
import 'package:shepaw/models/message.dart';

Message _msg({
  required String id,
  String content = '',
  String fromId = 'agent-1',
  Map<String, dynamic>? metadata,
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: 1,
    from: MessageFrom(id: fromId, type: 'agent', name: 'A'),
    to: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('ChatLifecycleCoordinator', () {
    test('records background timestamp and signals resume once', () {
      final life = ChatLifecycleCoordinator();
      expect(life.onLifecycleChanged(false, nowMs: 1000), isFalse);
      expect(life.backgroundedAtMs, 1000);
      // Second background keeps the first timestamp.
      expect(life.onLifecycleChanged(false, nowMs: 1500), isFalse);
      expect(life.backgroundedAtMs, 1000);

      expect(life.onLifecycleChanged(true, nowMs: 2000), isTrue);
      expect(life.takeBackgroundedAtMs(), 1000);
      expect(life.backgroundedAtMs, isNull);
      // Already active — further resume is a no-op signal.
      expect(life.onLifecycleChanged(true, nowMs: 2100), isFalse);
    });

    test('backgroundDuration is null without timestamp', () {
      expect(ChatLifecycleCoordinator.backgroundDuration(null), isNull);
      expect(
        ChatLifecycleCoordinator.backgroundDuration(1000, nowMs: 1500),
        const Duration(milliseconds: 500),
      );
    });
  });

  group('ChatStreamingSession', () {
    test('append + applyContentTo updates list and map', () {
      final session = ChatStreamingSession()..begin('s1');
      final messages = [_msg(id: 's1')];
      final map = <String, Message>{'s1': messages.first};

      session.append('Hi');
      session.append('!');
      final updated = session.applyContentTo(messages, map);

      expect(updated?.content, 'Hi!');
      expect(messages.first.content, 'Hi!');
      expect(map['s1']?.content, 'Hi!');
    });

    test('applyMetadataTo merges without wiping existing keys', () {
      final session = ChatStreamingSession()..begin('s1');
      final messages = [
        _msg(id: 's1', metadata: {'progress_content': '…'}),
      ];
      final map = <String, Message>{'s1': messages.first};

      session.applyMetadataTo(messages, map, {'tool': 'ls'});
      expect(messages.first.metadata?['progress_content'], '…');
      expect(messages.first.metadata?['tool'], 'ls');
    });

    test('clear drops id and content', () {
      final session = ChatStreamingSession()..begin('s1');
      session.append('x');
      session.clear();
      expect(session.isActive, isFalse);
      expect(session.content, isEmpty);
    });
  });

  group('ChatStreamingText helpers', () {
    test('withUpdatedContent / withMergedMetadata preserve routing', () {
      final original = _msg(
        id: 'm1',
        content: 'a',
        metadata: {'k': 1},
      );
      final updated = ChatStreamingText.withUpdatedContent(original, 'b');
      expect(updated.content, 'b');
      expect(updated.id, 'm1');
      expect(updated.metadata?['k'], 1);

      final merged = ChatStreamingText.withMergedMetadata(original, {'k': 2, 'n': 3});
      expect(merged.metadata?['k'], 2);
      expect(merged.metadata?['n'], 3);
    });

    test('placeholder builds empty text bubble', () {
      final p = ChatStreamingText.placeholder(
        id: 'p1',
        from: MessageFrom(id: 'a', type: 'agent', name: 'A'),
        to: MessageFrom(id: 'u', type: 'user', name: 'U'),
        timestampMs: 9,
      );
      expect(p.id, 'p1');
      expect(p.content, isEmpty);
      expect(p.timestampMs, 9);
    });
  });

  group('PeerApprovalCompleterResolver', () {
    Message agentMsg(String id, String agentId) => _msg(id: id, fromId: agentId);

    test('completes by confirmation id first', () async {
      final slot = PendingInteractionSlot(
        agentId: 'agent-1',
        data: {'confirmation_id': 'cid-1'},
        result: Completer<Map<String, dynamic>?>(),
      );
      final pending = <String, PendingInteractionSlot>{'cid-1': slot};
      final ok = PeerApprovalCompleterResolver.completePending(
        pending,
        originalMessage: agentMsg('msg-1', 'agent-1'),
        actionId: 'allow',
        actionLabel: 'Allow',
        confirmationId: 'cid-1',
      );
      expect(ok, isTrue);
      expect(pending, isEmpty);
      expect(await slot.result.future, {
        'selected_action_id': 'allow',
        'selected_action_label': 'Allow',
        '_approval_submitted': true,
      });
    });

    test('skips mismatched confirmation_id when scanning by agent', () {
      final keep = PendingInteractionSlot(
        agentId: 'agent-1',
        data: {'confirmation_id': 'keep'},
        result: Completer<Map<String, dynamic>?>(),
      );
      final pending = <String, PendingInteractionSlot>{'other': keep};
      final ok = PeerApprovalCompleterResolver.completePending(
        pending,
        originalMessage: agentMsg('msg', 'agent-1'),
        actionId: 'allow',
        actionLabel: 'Allow',
        confirmationId: 'wanted',
      );
      expect(ok, isFalse);
      expect(pending['other'], same(keep));
      expect(keep.result.isCompleted, isFalse);
    });

    test('falls back to agent id when confirmation missing', () async {
      final slot = PendingInteractionSlot(
        agentId: 'agent-9',
        data: {},
        result: Completer<Map<String, dynamic>?>(),
      );
      final pending = <String, PendingInteractionSlot>{'x': slot};
      final ok = PeerApprovalCompleterResolver.completePending(
        pending,
        originalMessage: agentMsg('msg', 'agent-9'),
        actionId: 'allow',
        actionLabel: 'Allow',
      );
      expect(ok, isTrue);
      expect(await slot.result.future, containsPair('selected_action_id', 'allow'));
    });
  });
}
