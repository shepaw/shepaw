import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/composer_draft_service.dart';

void main() {
  test('set/get/clear draft by key', () {
    final service = ComposerDraftService();
    expect(service.getDraft('ch-1'), '');

    service.setDraft('ch-1', 'hello');
    expect(service.getDraft('ch-1'), 'hello');
    expect(service.getDraft('ch-2'), '');

    service.setDraft('ch-1', '   ');
    expect(service.getDraft('ch-1'), '');

    service.setDraft('ch-1', 'again');
    service.clearDraft('ch-1');
    expect(service.getDraft('ch-1'), '');
  });

  test('migrate moves draft when target empty', () {
    final service = ComposerDraftService();
    service.setDraft('agent:a1', 'draft');
    service.migrate(fromKey: 'agent:a1', toKey: 'ch-1');
    expect(service.getDraft('agent:a1'), '');
    expect(service.getDraft('ch-1'), 'draft');
  });

  test('migrate keeps existing target draft', () {
    final service = ComposerDraftService();
    service.setDraft('agent:a1', 'from-agent');
    service.setDraft('ch-1', 'from-channel');
    service.migrate(fromKey: 'agent:a1', toKey: 'ch-1');
    expect(service.getDraft('agent:a1'), '');
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
}
