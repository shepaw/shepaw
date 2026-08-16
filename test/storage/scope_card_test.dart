import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/scope_card.dart';

void main() {
  test('DM stable card: cognition + no owner flag + real memory-write id', () {
    final card = ScopeCard.forAgentDm(
      agentId: 'agent_xxx',
      deviceId: 'aaaaaaaaaaaaaaaa',
      injected: const ScopeCardInjected(soul: ScopeInjectLevel.full),
    );
    final md = card.toStableMarkdown();
    expect(md, contains('## 当前储物袋作用域'));
    expect(md, contains('store://cognition/aaaaaaaaaaaaaaaa/'));
    expect(md, contains('已内嵌全文'));
    expect(md, contains('不要'));
    expect(md, contains('agents.memory-write --id agent_xxx'));
    expect(md, isNot(contains('--owner')));
  });

  test('uri_only notes tell agent to store read', () {
    final md = ScopeCard.forAgentDm(
      agentId: 'agent_uri',
      deviceId: 'aaaaaaaaaaaaaaaa',
      injected: const ScopeCardInjected(),
    ).toStableMarkdown();
    expect(md, contains('未内嵌'));
    expect(md, contains('store read'));
  });

  test('Group card: no personal cognition URI, no memory write', () {
    final md = ScopeCard.forGroup(
      groupId: 'group_1',
      deviceId: 'bbbbbbbbbbbbbbbb',
    ).toStableMarkdown();
    expect(md, contains('mode: `group`'));
    expect(md, contains('无**个人'));
    expect(md, isNot(contains('memory-write --id')));
    expect(md, contains('cognition/<你的agentId>'));
  });

  test('Peer card: write_memory off', () {
    final md = ScopeCard.forPeerAgent(
      agentId: 'agent_p',
      deviceId: 'cccccccccccccccc',
      peerClientId: 'peer_device',
    ).toStableMarkdown();
    expect(md, contains('mode: `peer`'));
    expect(md, contains('peers/peer_device'));
    expect(md, contains('禁止'));
    expect(md, isNot(contains('memory-write --id agent_p')));
  });

  test('volatile lists URIs separately from stable', () {
    final card = ScopeCard.forAgentDm(
      agentId: 'a1',
      deviceId: 'dddddddddddddddd',
    );
    expect(card.toStableMarkdown(), isNot(contains('本轮 URI')));
    expect(card.toVolatileMarkdown(), contains('本轮 URI'));
    expect(card.toVolatileMarkdown(), contains('context.manifest.json'));
  });

  test('dedupeUris strips ref/query', () {
    final out = ScopeCard.dedupeUris([
      'store://runtime/aa/a/x.md@abc',
      'store://runtime/aa/a/x.md',
      'store://runtime/aa/a/x.md?ref=1',
    ]);
    expect(out.length, 1);
  });
}
