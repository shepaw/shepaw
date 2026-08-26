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

  /// 敏感目标：即使动词是 read/grep/cat 等低风险读操作，指向这些路径/口令
  /// 的访问也必须显式确认（M13f）。
  static const _sensitiveTargetPatterns = [
    '/etc/passwd',
    '/etc/shadow',
    'id_rsa',
    '.ssh',
    '.pem',
    '.key',
    'credentials',
    'password',
    'passwd',
    'secret',
    'token',
    'api_key',
    'apikey',
    '.env',
    '/proc/',
    '/var/',
    'sudoers',
    'sudo',
  ];

  /// 词边界匹配：避免 `cat` 命中 "category"、`ls` 命中 "class"、`read` 命中
  /// "thread" 这类子串误判（M13f）。
  static final List<RegExp> _sensitiveRegExps =
      _toWordRegExps(_sensitiveTargetPatterns);
  static final List<RegExp> _highRiskRegExps =
      _toWordRegExps(_highRiskPatterns);
  static final List<RegExp> _lowRiskRegExps =
      _toWordRegExps(_lowRiskPatterns);

  static List<RegExp> _toWordRegExps(List<String> patterns) => [
        for (final p in patterns)
          RegExp('(^|[^a-z0-9])${RegExp.escape(p)}([^a-z0-9]|\$)'),
      ];

  /// Classify approval risk from hub-forwarded metadata.
  static PeerApprovalRisk classifyRisk(Map<String, dynamic> data) {
    final toolKind = (data['tool_kind'] as String? ?? '').toLowerCase();
    final prompt = (data['prompt'] as String? ?? '').toLowerCase();
    final haystack = '$toolKind $prompt';

    // 敏感目标优先——读 /etc/passwd、~/.ssh/id_rsa 不能因动词是读而自动放行。
    for (final re in _sensitiveRegExps) {
      if (re.hasMatch(haystack)) return PeerApprovalRisk.high;
    }

    for (final re in _highRiskRegExps) {
      if (re.hasMatch(haystack)) return PeerApprovalRisk.high;
    }

    for (final re in _lowRiskRegExps) {
      if (re.hasMatch(haystack)) return PeerApprovalRisk.low;
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
