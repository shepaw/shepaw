import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/services/composer_draft_service.dart';

void main() {
  test('set/get/clear draft by key', () {
    final service = ComposerDraftService();
    expect(service.getDraft('ch-1'), '');

    service.setDraft('ch-1', 'hello');
    expect(service.getDraft('ch-1'), 'hello');
    expect(service.getDraft('ch-2'), '');
    expect(service.draftUpdatedAt('ch-1'), isNotNull);

    service.setDraft('ch-1', '   ');
    expect(service.getDraft('ch-1'), '');
    expect(service.draftUpdatedAt('ch-1'), isNull);

    service.setDraft('ch-1', 'again');
    service.clearDraft('ch-1');
    expect(service.getDraft('ch-1'), '');
  });

  test('dual-writes agent and group list aliases', () {
    final service = ComposerDraftService();
    service.setDraft(
      'ch-1',
      'hello',
      agentId: 'a1',
      groupFamilyId: 'g1',
    );
    expect(service.getDraft('ch-1'), 'hello');
    expect(service.getDraft(ComposerDraftService.agentListKey('a1')), 'hello');
    expect(service.getDraft(ComposerDraftService.groupListKey('g1')), 'hello');

    service.clearDraft('ch-1', agentId: 'a1', groupFamilyId: 'g1');
    expect(service.getDraft('ch-1'), '');
    expect(service.getDraft(ComposerDraftService.agentListKey('a1')), '');
    expect(service.getDraft(ComposerDraftService.groupListKey('g1')), '');
  });

  test('migrate copies draft and keeps list aliases', () {
    final service = ComposerDraftService();
    service.setDraft('agent:a1', 'draft');
    service.migrate(fromKey: 'agent:a1', toKey: 'ch-1');
    expect(service.getDraft('agent:a1'), 'draft');
    expect(service.getDraft('ch-1'), 'draft');
  });

  test('migrate drops non-alias source keys', () {
    final service = ComposerDraftService();
    service.setDraft('temp-key', 'draft');
    service.migrate(fromKey: 'temp-key', toKey: 'ch-1');
    expect(service.getDraft('temp-key'), '');
    expect(service.getDraft('ch-1'), 'draft');
  });

  test('migrate keeps existing target draft', () {
    final service = ComposerDraftService();
    service.setDraft('agent:a1', 'from-agent');
    service.setDraft('ch-1', 'from-channel');
    service.migrate(fromKey: 'agent:a1', toKey: 'ch-1');
    expect(service.getDraft('agent:a1'), 'from-agent');
    expect(service.getDraft('ch-1'), 'from-channel');
  });

  test('keyFor prefers channelId over agentId', () {
    expect(
      ComposerDraftService.keyFor(channelId: 'ch-1', agentId: 'a1'),
      'ch-1',
    );
    expect(
      ComposerDraftService.keyFor(channelId: null, agentId: 'a1'),
      'agent:a1',
    );
    expect(ComposerDraftService.keyFor(), isNull);
  });

  test('publish and notify flag notify listeners', () {
    final service = ComposerDraftService();
    var count = 0;
    service.addListener(() => count++);

    service.setDraft('ch-1', 'quiet');
    expect(count, 0);

    service.setDraft('ch-1', 'loud', notify: true);
    expect(count, 1);

    service.publish();
    expect(count, 2);

    service.clearDraft('ch-1');
    expect(count, 3);
  });

  test('setDraft does not bump updatedAt when text is unchanged', () {
    final service = ComposerDraftService();
    service.setDraft('ch-1', 'hello');
    final first = service.draftUpdatedAt('ch-1');
    service.setDraft('ch-1', 'hello');
    expect(service.draftUpdatedAt('ch-1'), first);
  });

  test('restoreFromDisk loads persisted drafts', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'composer_drafts_v1': '''
{"drafts":{"agent:a1":"saved draft"},"updatedAt":{"agent:a1":"2026-07-12T12:00:00.000Z"}}
''',
    });

    final service = ComposerDraftService();
    await service.restoreFromDisk();
    expect(service.getDraft('agent:a1'), 'saved draft');
    expect(service.draftUpdatedAt('agent:a1'), isNotNull);
  });
}
