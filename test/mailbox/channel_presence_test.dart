import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/channel_mailbox_service.dart';

void main() {
  test('unauthorized presence is not treated as inbox route', () {
    final p = AgentChannelPresence.fromJson({
      'agent_id': 'acp_agent_x',
      'online': false,
    });
    expect(p.authorized, isFalse);
    expect(p.useInbox, isFalse);
  });

  test('offline authorized agent uses inbox', () {
    final p = AgentChannelPresence.fromJson({
      'agent_id': 'acp_agent_x',
      'online': false,
      'last_seen_at': '2026-08-15T00:00:00Z',
      'capacity': 5,
      'active_count': 0,
      'busy': false,
    });
    expect(p.authorized, isTrue);
    expect(p.useInbox, isTrue);
  });

  test('busy authorized agent uses inbox', () {
    final p = AgentChannelPresence.fromJson({
      'agent_id': 'acp_agent_x',
      'online': true,
      'last_seen_at': '2026-08-15T00:00:00Z',
      'capacity': 5,
      'active_count': 5,
      'busy': true,
    });
    expect(p.online, isTrue);
    expect(p.busy, isTrue);
    expect(p.useInbox, isTrue);
  });

  test('idle online agent stays on live tunnel', () {
    final p = AgentChannelPresence.fromJson({
      'agent_id': 'acp_agent_x',
      'online': true,
      'last_seen_at': '2026-08-15T00:00:00Z',
      'capacity': 5,
      'active_count': 1,
      'busy': false,
    });
    expect(p.useInbox, isFalse);
  });
}
