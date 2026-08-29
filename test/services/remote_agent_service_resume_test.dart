import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/remote_agent_service.dart';
import 'package:shepaw/services/token_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import '../storage/test_harness.dart';

/// 储物袋简历（resume.md）固定位置 & Summary 解析。
///
/// 纯解析用例跑在默认 CI；store 往返用例用 StorageTestHarness mock 平台通道，
/// 与 test/storage/store_uri_reader_test.dart 同套路，同样无需 needs-plugins。
void main() {
  group('extractResumeSummaryFromMarkdown', () {
    test('extracts the Summary section body only', () {
      const md = '''
# Acme Agent — Agent Resume

## Capabilities
- chat

## Summary
Acme Agent — ACP agent gateway bridging Shepaw.
Workspace: acme — A demo project

## 自我补充 / Self Notes
<!-- SHEPAW_RESUME_NOTES_START -->
Manual notes
<!-- SHEPAW_RESUME_NOTES_END -->''';
      final summary = extractResumeSummaryFromMarkdown(md);
      expect(summary, contains('Acme Agent — ACP agent gateway'));
      expect(summary, contains('Workspace: acme'));
      expect(summary, isNot(contains('Manual notes')));
    });

    test('returns null when no Summary heading', () {
      expect(extractResumeSummaryFromMarkdown('# no summary'), isNull);
      expect(extractResumeSummaryFromMarkdown(''), isNull);
    });

    test('handles Summary as the last section', () {
      const md = '## Summary\nTrailing summary without following heading.';
      expect(
        extractResumeSummaryFromMarkdown(md),
        'Trailing summary without following heading.',
      );
    });
  });

  group('resume store round-trip', () {
    late RemoteAgentService service;

    setUpAll(() async {
      await StorageTestHarness.init();
      await StoreService.instance.start();
      service = RemoteAgentService(
        LocalDatabaseService(),
        TokenService(LocalDatabaseService()),
      );
    });

    test('resumeStoreUriFor builds the fixed pouch location', () async {
      final device = await DeviceIdentity.deviceId();
      final uri = await service.resumeStoreUriFor('acp_agent_abcd');
      expect(uri, 'store://files/$device/acp_agent_abcd/resume.md');
    });

    test('readResumeMarkdownFromStore reads back what was written', () async {
      const agentId = 'acp_agent_abcd';
      final device = await DeviceIdentity.deviceId();
      final content =
          Uint8List.fromList(utf8.encode('# resume\n\nbody\n'));
      final store = await StoreService.instance.localStore();
      final (uploadId, _) = await store.writeBegin(
        deviceId: device,
        space: StoreSpace.files,
        path: '$agentId/resume.md',
        size: content.length,
        sha256: crypto.sha256.convert(content).toString(),
      );
      await store.writeChunk(device, StoreSpace.files, uploadId, 0, content);
      await store.commit(device, StoreSpace.files, [uploadId]);

      final md = await service.readResumeMarkdownFromStore(agentId);
      expect(md, '# resume\n\nbody\n');
    });

    test('readResumeMarkdownFromStore returns null for a missing file',
        () async {
      final md = await service.readResumeMarkdownFromStore('acp_agent_missing');
      expect(md, isNull);
    });
  });

  group('card resume sync (fill vs overwrite)', () {
    late RemoteAgentService service;
    late LocalDatabaseService db;

    setUpAll(() async {
      await StorageTestHarness.init();
      await StoreService.instance.start();
      db = LocalDatabaseService();
      await db.database;
      service = RemoteAgentService(db, TokenService(db));
    });

    Future<RemoteAgent> seedAgent(String id, {String? bio}) async {
      return service.createAgent(
        name: 'Agent $id',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: 'wss://localhost/$id',
        bio: bio,
      );
    }

    test('syncResumeFromCardData fills an empty bio', () async {
      final agent = await seedAgent('agent_fill', bio: null);
      await service.syncResumeFromCardData(agent.id, {
        'bio': 'fresh summary from card',
      });
      final after = await service.getAgentById(agent.id);
      expect(after?.bio, 'fresh summary from card');
    });

    test('syncResumeFromCardData keeps an existing (user-filled) bio',
        () async {
      final agent = await seedAgent('agent_keep', bio: 'user written bio');
      await service.syncResumeFromCardData(agent.id, {
        'bio': 'fresh summary from card',
      });
      final after = await service.getAgentById(agent.id);
      expect(after?.bio, 'user written bio');
    });

    test('refreshResumeFromCard overwrites bio when a connection is active',
        () async {
      final agent = await seedAgent('agent_overwrite', bio: 'stale bio');
      final card = <String, dynamic>{'bio': 'brand new resume'};

      // Patch the live connection map so activeConnectionFor finds our fake.
      final chat = ChatService();
      chat.connectionsForTest[agent.id] = _FakeCardConnection(card);

      await service.refreshResumeFromCard(agent.id);
      final after = await service.getAgentById(agent.id);
      expect(after?.bio, 'brand new resume');
    });

    test('refreshResumeFromCard is a no-op without an active connection',
        () async {
      final agent = await seedAgent('agent_offline', bio: 'stale bio');
      await service.refreshResumeFromCard(agent.id);
      final after = await service.getAgentById(agent.id);
      expect(after?.bio, 'stale bio');
    });

    test('refreshResumeFromCard skips when the card bio is unchanged',
        () async {
      final agent = await seedAgent('agent_same', bio: 'same bio');
      final card = <String, dynamic>{'bio': 'same bio'};
      final chat = ChatService();
      chat.connectionsForTest[agent.id] = _FakeCardConnection(card);

      await service.refreshResumeFromCard(agent.id);
      final after = await service.getAgentById(agent.id);
      expect(after?.bio, 'same bio');
    });
  });
}

/// ACP connection double returning a canned `agent.getCard` result.
class _FakeCardConnection extends ACPAgentConnection {
  _FakeCardConnection(this.card) : super(agentId: 'fake');

  final Map<String, dynamic> card;

  @override
  bool get isConnected => true;

  @override
  Future<ACPResponse> getAgentCard() async {
    return ACPResponse.success(id: 1, result: card);
  }
}
