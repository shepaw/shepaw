import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/services/group/peer_approval_policy.dart';

void main() {
  group('PeerApprovalPolicy.classifyRisk', () {
    test('treats read-style prompts as low risk', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'tool_kind': 'unknown',
          'prompt': 'Read lib/screens/chat_screen.dart layout',
        }),
        PeerApprovalRisk.low,
      );
    });

    test('treats analyze prompts as low risk', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'prompt': 'Analyze Flutter keyboard inset handling',
        }),
        PeerApprovalRisk.low,
      );
    });

    test('treats shell exec as high risk', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'tool_kind': 'bash',
          'prompt': 'Run tests',
        }),
        PeerApprovalRisk.high,
      );
    });

    test('write still wins over read when both appear', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'prompt': 'read file then write patch',
        }),
        PeerApprovalRisk.high,
      );
    });

    test('unknown tools default to high risk', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'tool_kind': 'mystery_tool',
          'prompt': 'do the thing',
        }),
        PeerApprovalRisk.high,
      );
    });

    test('network patterns are high risk', () {
      expect(
        PeerApprovalPolicy.classifyRisk({
          'prompt': 'curl https://example.com',
        }),
        PeerApprovalRisk.high,
      );
    });
  });

  group('PeerApprovalPolicy.allowAdminAutoResolve', () {
    test('allows low-risk prompts', () {
      expect(
        PeerApprovalPolicy.allowAdminAutoResolve({
          'prompt': 'grep LocalUserIdentity',
        }),
        isTrue,
      );
    });

    test('blocks high-risk prompts', () {
      expect(
        PeerApprovalPolicy.allowAdminAutoResolve({
          'tool_kind': 'bash',
          'prompt': 'Run tests',
        }),
        isFalse,
      );
    });
  });

  group('PeerApprovalPolicy.workflowSessionId', () {
    test('returns null when workflow or step missing', () {
      expect(
        PeerApprovalPolicy.workflowSessionId(
          channelId: 'ch',
          workflowId: null,
          workflowStepId: 's1',
        ),
        isNull,
      );
      expect(
        PeerApprovalPolicy.workflowSessionId(
          channelId: 'ch',
          workflowId: '',
          workflowStepId: 's1',
        ),
        isNull,
      );
      expect(
        PeerApprovalPolicy.workflowSessionId(
          channelId: 'ch',
          workflowId: 'wf',
          workflowStepId: '',
        ),
        isNull,
      );
    });

    test('scopes session by channel, workflow, and step', () {
      expect(
        PeerApprovalPolicy.workflowSessionId(
          channelId: 'ch-1',
          workflowId: 'wf-9',
          workflowStepId: 'step-2',
        ),
        'ch-1__wf_wf-9__step_step-2',
      );
    });
  });
}
