import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/agent_roster.dart';

void main() {
  late Directory root;
  var seq = 0;

  setUp(() async {
    seq = 0;
    root = await Directory.systemTemp.createTemp('agent_roster_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  AgentRosterStore store() => AgentRosterStore(
        root,
        newId: () => 'card-${seq++}',
      );

  test('工人 Hub 上报后可拨号，再连对上原卡', () async {
    final roster = store();
    final first = await roster.upsertWorker(
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
      name: 'Codex',
      engine: 'codex',
      running: true,
      workspaceUri: 'store://workspaces/hubaaaa/proj',
    );
    expect(first.id, 'card-0');
    expect(first.dialable, isTrue);

    await roster.detachHub('hubaaaa');
    final detached = await roster.findById('card-0');
    expect(detached, isNotNull);
    expect(detached!.dial, isNull);
    expect(detached.dialable, isFalse);
    expect(detached.name, 'Codex');
    expect(await roster.dialable(), isEmpty);

    final again = await roster.upsertWorker(
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
      name: 'Codex',
      engine: 'codex',
      running: false,
    );
    expect(again.id, 'card-0');
    expect(again.dialable, isTrue);
    expect(await roster.dialable(), hasLength(1));
  });

  test('卸掉一台 Hub 不影响另一台和惜宝', () async {
    final roster = store();
    await roster.ensurePouchBound(
      id: 'she-builtin-agent-001',
      name: 'She',
      engine: 'she',
    );
    await roster.upsertWorker(
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'a',
      name: 'A',
    );
    await roster.upsertWorker(
      hubFingerprint: 'hubbbbb',
      remoteAgentId: 'b',
      name: 'B',
    );

    await roster.detachHub('hubaaaa');
    final cards = await roster.load();
    expect(cards.map((c) => c.id), [
      'she-builtin-agent-001',
      'card-0',
      'card-1',
    ]);
    expect(cards[0].boundToPouch, isTrue);
    expect(cards[0].dialable, isFalse);
    expect(cards[1].dial, isNull);
    expect(cards[2].dialable, isTrue);
  });

  test('惜宝卡已存在时不覆盖名字', () async {
    final roster = store();
    await roster.ensurePouchBound(id: 'she', name: 'She');
    final again = await roster.ensurePouchBound(id: 'she', name: '惜宝');
    expect(again.name, 'She');
    expect(await roster.load(), hasLength(1));
  });

  test('头像字节跟卡一起落在 .system', () async {
    final roster = store();
    final card = await roster.upsertWorker(
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
      name: 'Codex',
      avatarBytes: Uint8List.fromList(const [1, 2, 3, 4]),
    );
    expect(card.avatarFile, isNotNull);
    expect(await roster.readAvatar(card), [1, 2, 3, 4]);
    final raw = jsonDecode(await rosterFile(root).readAsString());
    expect(raw['v'], 1);
  });
}

File rosterFile(Directory root) =>
    File('${root.path}/.system/${AgentRosterStore.fileName}');
