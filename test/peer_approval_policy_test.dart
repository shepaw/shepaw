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
  });
}
