import '../../models/workflow_models.dart';

/// Heuristic policy for when peer tool approvals require explicit user consent.
class PeerApprovalPolicy {
  PeerApprovalPolicy._();

  static const _highRiskPatterns = [
    'bash',
    'shell',
    'exec',
    'execute',
    'write',
    'delete',
    'remove',
    'unlink',
    'network',
    'curl',
    'wget',
    'fetch',
    'http',
    'socket',
    'chmod',
    'mv ',
    'rm ',
    'install',
    'deploy',
    'patch',
  ];

  static const _lowRiskPatterns = [
    'read',
    'list',
    'get',
    'search',
    'grep',
    'cat',
    'view',
    'show',
    'ls',
    'stat',
    'head',
    'tail',
    'analyze',
    'analysis',
    'inspect',
    'describe',
    'explain',
    'glob',
    'find',
    'locate',
    'dart',
    'flutter',
    'widget',
    'layout',
    'screen',
    'ui',
    'code',
    'file',
    'directory',
    'diff',
    'status',
    'log',
  ];

  /// Classify approval risk from hub-forwarded metadata.
  static PeerApprovalRisk classifyRisk(Map<String, dynamic> data) {
    final toolKind = (data['tool_kind'] as String? ?? '').toLowerCase();
    final prompt = (data['prompt'] as String? ?? '').toLowerCase();
    final haystack = '$toolKind $prompt';

    for (final pattern in _highRiskPatterns) {
      if (haystack.contains(pattern)) {
        return PeerApprovalRisk.high;
      }
    }

    for (final pattern in _lowRiskPatterns) {
      if (haystack.contains(pattern)) {
        return PeerApprovalRisk.low;
      }
    }

    // Unknown tools default to high risk during workflow execution.
    return PeerApprovalRisk.high;
  }

  /// Whether group admin may auto-decide this peer approval.
  static bool allowAdminAutoResolve(Map<String, dynamic> data) {
    return classifyRisk(data) == PeerApprovalRisk.low;
  }

  /// Scoped peer session id so workflow steps do not share DM/group history.
  ///
  /// 格式：`<channelId>__wf_<workflowId>__step_<workflowStepId>`。
  /// 储物袋路径会拆成两级目录：
  /// `runtime/<owner>/<channelId>/wf_<wf>__step_<step>/…`
  /// （见 RuntimePaths.channelRoot / workflowScopeMarker）。
  static String? workflowSessionId({
    required String channelId,
    required String? workflowId,
    required String? workflowStepId,
  }) {
    if (workflowId == null ||
        workflowId.isEmpty ||
        workflowStepId == null ||
        workflowStepId.isEmpty) {
      return null;
    }
    return '${channelId}__wf_${workflowId}__step_$workflowStepId';
  }
}
