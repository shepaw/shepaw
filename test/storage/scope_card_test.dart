import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/scope_card.dart';

void main() {
  test('DM stable card: cognition + no owner flag + real memory-write id', () {
    final card = ScopeCard.forAgentDm(
      agentId: 'agent_xxx',
      deviceId: 'aaaaaaaaaaaaaaaa',
      pouchId: 'pouch-test',
      injected: const ScopeCardInjected(soul: ScopeInjectLevel.full),
    );
    final md = card.toStableMarkdown();
    expect(md, contains('## 当前储物袋作用域'));
    expect(md, contains('pouch://pouch-test/agent:agent_xxx'));
    expect(md, contains('pouch://pouch-test/agent:agent_xxx/identity/soul.md'));
    expect(md, contains('pouch://pouch-test/agent:agent_xxx/memory/entries/'));
    expect(md, contains('已内嵌全文'));
    expect(md, contains('不要'));
    expect(md, contains('agents.memory-write --id agent_xxx'));
    expect(md, isNot(contains('--owner')));
    expect(md, contains('`agent:<id>` 认知'));
    expect(md, contains('`runtime` 运行时'));
    expect(md, contains('`workspaces` 工作区'));
    expect(md, contains('`tools` 工具'));
    expect(md, contains('`files` 沉淀'));
    expect(md, contains('`public` 用途未定，不要写入'));
    expect(md, isNot(contains('--space public')));
    expect(md, contains('@v<n>'));
    expect(md, contains('记忆补充'));
    expect(md, contains('改磁盘即改袋'));
    expect(md, contains('旧分区 `artifacts` 不要再写'));
    expect(md, contains('pouch://tools/'));
    expect(md, contains('pouch://tools/agents/agent_xxx/'));
    expect(md, isNot(contains('产物/runtime')));
  });

  test('uri_only notes tell agent to store read', () {
    final md = ScopeCard.forAgentDm(
      agentId: 'agent_uri',
      deviceId: 'aaaaaaaaaaaaaaaa',
      pouchId: 'pouch-test',
      injected: const ScopeCardInjected(),
    ).toStableMarkdown();
    expect(md, contains('未内嵌'));
    expect(md, contains('pouch read'));
    expect(md, contains('pouch search'));
  });

  test('Group card: no personal cognition URI, no memory write', () {
    final md = ScopeCard.forGroup(
      groupId: 'group_1',
      deviceId: 'bbbbbbbbbbbbbbbb',
    ).toStableMarkdown();
    expect(md, contains('mode: `group`'));
    expect(md, contains('无**个人'));
    expect(md, isNot(contains('memory-write --id')));
    expect(md, contains('agent:<你的agentId>'));
  });

  test('Peer card: write_memory off', () {
    final md = ScopeCard.forPeerAgent(
      agentId: 'agent_p',
      deviceId: 'cccccccccccccccc',
      pouchId: 'pouch-test',
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
      pouchId: 'pouch-test',
    );
    expect(card.toStableMarkdown(), isNot(contains('本轮 URI')));
    expect(card.toVolatileMarkdown(), contains('本轮 URI'));
    expect(card.toVolatileMarkdown(), contains('context.manifest.json'));
  });

  test('dedupeUris strips ref/query', () {
    final out = ScopeCard.dedupeUris([
      'pouch://runtime/aa/a/x.md@abc',
      'pouch://runtime/aa/a/x.md',
      'pouch://runtime/aa/a/x.md?ref=1',
    ]);
    expect(out.length, 1);
  });

  test('dedupeUris folds ancestor roots under file URIs', () {
    final out = ScopeCard.dedupeUris([
      'pouch://runtime/agent1/',
      'pouch://runtime/agent1/ch/artifacts/t/a.md',
      'pouch://cognition/agent1/soul.md',
    ]);
    expect(
      out,
      contains('pouch://runtime/agent1/ch/artifacts/t/a.md'),
    );
    expect(
      out,
      contains('pouch://cognition/agent1/soul.md'),
    );
    expect(
      out.any((u) =>
          ScopeCard.normalizeUriKey(u) ==
          'pouch://runtime/agent1/'),
      isFalse,
    );
  });

  test('hub CLI surface teaches hub.cli.execute instead of shepaw tool', () {
    final md = ScopeCard.forAgentDm(
      agentId: 'agent_hub',
      deviceId: 'aaaaaaaaaaaaaaaa',
      pouchId: 'pouch-test',
      cliSurface: ScopeCardCliSurface.hubExecuteCli,
    ).toStableMarkdown();
    expect(md, contains('hub.cli.execute'));
    expect(md, contains('session_id'));
    expect(md, contains('pouch'));
    expect(md, isNot(contains('shepaw pouch read')));
    expect(md, isNot(contains('shepaw pouch write')));
    expect(md, contains('不要'));
    expect(md, contains('agent_id'));
  });

  test('volatileUrisMarkdown hub surface uses hub.cli.execute', () {
    final md = ScopeCard.volatileUrisMarkdown(
      ['pouch://files/a.txt'],
      cliSurface: ScopeCardCliSurface.hubExecuteCli,
    );
    expect(md, contains('hub.cli.execute'));
    expect(md, isNot(contains('shepaw pouch read')));
  });

  test('surfaceFor: remote ACP uses hub, local and peer use shepaw, Hub engine uses store',
      () {
    expect(
      ScopeCard.surfaceFor(isLocal: false, isPeerAgent: false),
      ScopeCardCliSurface.hubExecuteCli,
    );
    expect(
      ScopeCard.surfaceFor(isLocal: true, isPeerAgent: false),
      ScopeCardCliSurface.shepawTool,
    );
    expect(
      ScopeCard.surfaceFor(isLocal: true, isPeerAgent: true),
      ScopeCardCliSurface.shepawTool,
    );
    expect(
      ScopeCard.surfaceFor(
        isLocal: false,
        isPeerAgent: true,
        isHubPeerEngine: true,
      ),
      ScopeCardCliSurface.hubStoreCli,
    );
  });

  test('Hub peer card says slip is forwarded and points at the system skill', () {
    final md = ScopeCard.forPeerAgent(
      agentId: 'agent_p',
      deviceId: 'cccccccccccccccc',
      pouchId: 'pouch-test',
      peerClientId: 'peer_device',
      cliSurface: ScopeCardCliSurface.hubStoreCli,
    ).toStableMarkdown();
    expect(md, contains('玉简'));
    expect(md, contains('转到配对 App'));
    expect(md, contains('不要 `hub.cli.execute`'));
    expect(md, contains('pouch://tools/skills/shepaw-system/SKILL.md'));
    expect(md, contains('shepaw pouch read'));
    expect(md, contains('勾选是提交'));
  });

  test('hub store surface teaches local store plus App-forwarded CLI', () {
    final md = ScopeCard.forGroup(
      groupId: 'g1',
      deviceId: 'dddddddddddddddd',
      cliSurface: ScopeCardCliSurface.hubStoreCli,
      workspaceUris: const [
        'pouch://workspaces/Users/me/proj/',
      ],
    ).toStableMarkdown();
    expect(md, contains('shepaw pouch write'));
    expect(md, contains('当前作用域'));
    expect(md, contains('转到配对 App'));
    expect(md, contains('工作区已挂载'));
    expect(md, contains('不要 `hub.cli.execute`'));
    expect(md, isNot(contains('agents.memory-write')));
    expect(md, isNot(contains('session-new')));
    expect(md, isNot(contains('session create')));
  });

  test('volatileUrisMarkdown lists folded URIs once', () {
    final md = ScopeCard.volatileUrisMarkdown([
      'pouch://files/a.txt',
      'pouch://files/a.txt@deadbeef',
    ]);
    expect(md, contains('当前储物袋作用域 · 本轮'));
    expect(md, contains('pouch://files/a.txt'));
    expect('[implicit]'.allMatches(md).length, 0);
  });
}
