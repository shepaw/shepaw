import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';

void main() {
  group('PeerApprovalExpiredException', () {
    test('matches typed exception and legacy message', () {
      expect(
        PeerApprovalExpiredException.matches(
          const PeerApprovalExpiredException(),
        ),
        isTrue,
      );
      expect(
        PeerApprovalExpiredException.matches(
          Exception('审批已失效（对话已结束或结果已提交），无需重复操作'),
        ),
        isTrue,
      );
      expect(
        PeerApprovalExpiredException.matches(Exception('peer not connected')),
        isFalse,
      );
      expect(PeerApprovalExpiredException.matches(null), isFalse);
    });

    test('toString exposes user-facing message', () {
      expect(
        const PeerApprovalExpiredException().toString(),
        contains('审批已失效'),
      );
    });
  });

  group('PeerApprovalPayload', () {
    test('normalizeApprovalId keeps non-empty hub id', () {
      expect(
        PeerApprovalPayload.normalizeApprovalId('appr-1', 'req-1'),
        'appr-1',
      );
    });

    test('normalizeApprovalId synthesizes id when hub omits it', () {
      expect(
        PeerApprovalPayload.normalizeApprovalId(null, 'req-9'),
        'missing_req-9',
      );
      expect(
        PeerApprovalPayload.normalizeApprovalId('', 'req-9'),
        'missing_req-9',
      );
    });

    test('effectiveActions keeps hub actions', () {
      final actions = [
        {'id': 'yes', 'label': 'Yes'},
      ];
      expect(PeerApprovalPayload.effectiveActions(actions), actions);
    });

    test('effectiveActions falls back to Allow/Deny', () {
      final actions = PeerApprovalPayload.effectiveActions(const []);
      expect(actions.length, 2);
      expect(actions[0]['id'], 'allow');
      expect(actions[1]['id'], 'deny');
    });

    test('buildActionConfirmationData marks peer context', () {
      final data = PeerApprovalPayload.buildActionConfirmationData(
        data: {
          'prompt': 'Run ls',
          'tool_kind': 'bash',
          'tool_call_id': 'tc-1',
        },
        approvalId: 'appr-1',
        actions: PeerApprovalPayload.effectiveActions(null),
      );
      expect(data['confirmation_id'], 'appr-1');
      expect(data['confirmation_context'], 'peer');
      expect(data['prompt'], 'Run ls');
      expect(data['tool_kind'], 'bash');
      expect(data['tool_call_id'], 'tc-1');
      expect(data['actions'], isA<List>());
    });
  });

  group('PeerApprovalTurnGate', () {
    test('buffers agent_done while approvals are open', () {
      final gate = PeerApprovalTurnGate();
      gate.onApprovalOpened();
      expect(gate.bufferDoneIfApprovalsOpen({'content': 'done'}), isTrue);
      expect(gate.tryCompleteBufferedDone(), isNull);

      expect(gate.onApprovalResolved(), isTrue);
      expect(gate.tryCompleteBufferedDone(), {'content': 'done'});
      expect(gate.bufferedDone, isNull);
    });

    test('does not buffer when gate is already clear', () {
      final gate = PeerApprovalTurnGate();
      expect(gate.bufferDoneIfApprovalsOpen({'content': 'done'}), isFalse);
      expect(gate.bufferedDone, isNull);
    });

    test('onApprovalResolved is a no-op at zero', () {
      final gate = PeerApprovalTurnGate();
      expect(gate.onApprovalResolved(), isFalse);
      expect(gate.openApprovals, 0);
    });

    test('sequential approvals release buffered done only at zero', () {
      final gate = PeerApprovalTurnGate();
      gate.onApprovalOpened();
      gate.onApprovalOpened();
      gate.bufferDoneIfApprovalsOpen({'ok': true});

      gate.onApprovalResolved();
      expect(gate.tryCompleteBufferedDone(), isNull);

      gate.onApprovalResolved();
      expect(gate.tryCompleteBufferedDone(), {'ok': true});
    });
  });
}
