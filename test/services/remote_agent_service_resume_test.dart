import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/local_database_service.dart';
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
}
