import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/channel_mailbox_service.dart';

void main() {
  test('LAN ACP endpoints are not treated as channel relays', () {
    expect(
      ChannelMailboxService.isChannelRelayEndpoint(
        'ws://192.168.1.8:8080/acp/ws',
      ),
      isFalse,
    );
    expect(
      ChannelMailboxService.channelBaseFromEndpoint(
        'ws://127.0.0.1:18789/acp/ws?agentId=acp_agent_aabbccdd',
      ),
      isNull,
    );
  });

  test('channel proxy and alias URLs resolve to origin', () {
    expect(
      ChannelMailboxService.channelBaseFromEndpoint(
        'wss://channel.example.com/proxy/ch1/acp/ws?agentId=acp_agent_aabbccdd',
      ),
      'https://channel.example.com',
    );
    expect(
      ChannelMailboxService.channelBaseFromEndpoint(
        'wss://channel.example.com/proxy/ch1/p/inst1/acp/ws',
      ),
      'https://channel.example.com',
    );
    expect(
      ChannelMailboxService.channelBaseFromEndpoint(
        'https://channel.example.com/c/mybot/acp/ws',
      ),
      'https://channel.example.com',
    );
  });
}
