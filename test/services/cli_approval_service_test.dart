import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/cli_approval_coordinator.dart';
import 'package:shepaw/services/cli_approval_service.dart';

Message _cliCard({
  required String id,
  required String confirmationId,
  String? selected,
}) {
  return Message(
    id: id,
    from: MessageFrom(id: 'a', type: 'agent', name: 'A'),
    type: MessageType.text,
    content: 'confirm',
    timestampMs: 1,
    metadata: {
      'action_confirmation': {
        'confirmation_id': confirmationId,
        'confirmation_context': 'cli',
        'tool_name': 'peer.list',
        if (selected != null) 'selected_action_id': selected,
      },
    },
  );
}

void main() {
  setUp(() {
    CliApprovalService.instance.resetForTest();
    CliApprovalCoordinator.instance.resetForTest();
  });

  test('complete resolves awaitApproval', () async {
    final future = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_1',
      toolName: 'peer.list',
      channelId: 'ch',
    );
    expect(CliApprovalService.instance.hasLive('cli_1'), isTrue);
    CliApprovalService.instance.complete('cli_1', approved: true);
    expect(await future, isTrue);
    expect(CliApprovalService.instance.hasLive('cli_1'), isFalse);
  });

  test('cancel denies the waiter', () async {
    final future = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_2',
      toolName: 'peer.list',
      channelId: 'ch',
    );
    CliApprovalService.instance.cancel('cli_2');
    expect(await future, isFalse);
  });

  test('rememberSession grants the coordinator', () async {
    final future = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_3',
      toolName: 'peer.list',
      channelId: 'ch',
    );
    CliApprovalService.instance.complete(
      'cli_3',
      approved: true,
      rememberSession: true,
    );
    expect(await future, isTrue);
    expect(
      CliApprovalCoordinator.instance.isGrantedForSession('peer.list'),
      isTrue,
    );
  });

  test('cancelForChannel only denies that channel', () async {
    final a = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_a',
      toolName: 'peer.list',
      channelId: 'ch-a',
    );
    final b = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_b',
      toolName: 'peer.list',
      channelId: 'ch-b',
    );
    CliApprovalService.instance.cancelForChannel('ch-a');
    expect(await a, isFalse);
    expect(CliApprovalService.instance.hasLive('cli_b'), isTrue);
    CliApprovalService.instance.complete('cli_b', approved: true);
    expect(await b, isTrue);
  });

  test('awaitApproval times out as denied', () async {
    final future = CliApprovalService.instance.awaitApproval(
      confirmationId: 'cli_timeout',
      toolName: 'store.write',
      channelId: 'ch',
      timeout: const Duration(milliseconds: 30),
    );
    expect(CliApprovalService.instance.hasLive('cli_timeout'), isTrue);
    expect(await future, isFalse);
    expect(CliApprovalService.instance.hasLive('cli_timeout'), isFalse);
  });

  test('expireStaleCards skips live completers and already-answered cards', () {
    CliApprovalService.instance.awaitApproval(
      confirmationId: 'live',
      toolName: 'peer.list',
      channelId: 'ch',
    );
    final messages = [
      _cliCard(id: 'm1', confirmationId: 'stale'),
      _cliCard(id: 'm2', confirmationId: 'live'),
      _cliCard(id: 'm3', confirmationId: 'done', selected: 'allow'),
      Message(
        id: 'm4',
        from: MessageFrom(id: 'a', type: 'agent', name: 'A'),
        type: MessageType.text,
        content: 'other',
        timestampMs: 1,
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'peer-1',
            'confirmation_context': 'peer',
          },
        },
      ),
    ];
    expect(
      CliApprovalService.instance.expireStaleCards(messages),
      ['m1'],
    );
  });
}
