import 'group_orchestration_features.dart';

/// Admin loop-summarize prompt assembly with a character budget (Phase 2 M).
///
/// When the assembled turn exceeds [GroupOrchestrationFeatures.adminContextBudgetChars],
/// switches to compact mode: dispatch JSON → store URI, results scoped to the
/// current round, artifact blocks URI-only.
class GroupAdminContextBudget {
  GroupAdminContextBudget._();

  static int get budgetChars =>
      GroupOrchestrationFeatures.adminContextBudgetChars;

  /// Builds admin loop-summarize user content, applying compact mode when over budget.
  static String assembleLoopSummarizeContent({
    required String adminSummarizeBase,
    String? lastDispatchNote,
    String? dispatchUri,
    required String memberArtifactsBlock,
    required String structuredResultsBlock,
    required String structuredResultsCompactBlock,
    required String summarizeArtifactNotes,
    required String summarizeArtifactCompactNotes,
    required String pendingNote,
    required String sessionHandoffSuffix,
    String? resultsUri,
  }) {
    if (budgetChars <= 0) {
      return _full(
        adminSummarizeBase: adminSummarizeBase,
        lastDispatchNote: lastDispatchNote,
        memberArtifactsBlock: memberArtifactsBlock,
        structuredResultsBlock: structuredResultsBlock,
        summarizeArtifactNotes: summarizeArtifactNotes,
        pendingNote: pendingNote,
        sessionHandoffSuffix: sessionHandoffSuffix,
      );
    }

    final full = _full(
      adminSummarizeBase: adminSummarizeBase,
      lastDispatchNote: lastDispatchNote,
      memberArtifactsBlock: memberArtifactsBlock,
      structuredResultsBlock: structuredResultsBlock,
      summarizeArtifactNotes: summarizeArtifactNotes,
      pendingNote: pendingNote,
      sessionHandoffSuffix: sessionHandoffSuffix,
    );
    if (full.length <= budgetChars) return full;

    final compact = _compact(
      adminSummarizeBase: adminSummarizeBase,
      dispatchUri: dispatchUri,
      memberArtifactsBlock: memberArtifactsBlock,
      structuredResultsBlock: structuredResultsCompactBlock,
      summarizeArtifactNotes: summarizeArtifactCompactNotes,
      pendingNote: pendingNote,
      sessionHandoffSuffix: sessionHandoffSuffix,
      resultsUri: resultsUri,
    );
    if (compact.length <= budgetChars) return compact;

    // Still over budget: drop artifact plan noise and member artifact dupes.
    final minimal = _compact(
      adminSummarizeBase: adminSummarizeBase,
      dispatchUri: dispatchUri,
      memberArtifactsBlock: '',
      structuredResultsBlock: structuredResultsCompactBlock,
      summarizeArtifactNotes: summarizeArtifactCompactNotes,
      pendingNote: pendingNote,
      sessionHandoffSuffix: '',
      resultsUri: resultsUri,
    );
    if (minimal.length <= budgetChars) return minimal;

    return '[SYSTEM] 上下文已超预算，进入摘要模式。'
        '${resultsUri != null ? ' results.json: $resultsUri' : ''}'
        '${dispatchUri != null ? ' dispatch: $dispatchUri' : ''}\n'
        '$adminSummarizeBase'
        '$structuredResultsCompactBlock'
        '$summarizeArtifactCompactNotes'
        '$pendingNote';
  }

  static String _full({
    required String adminSummarizeBase,
    String? lastDispatchNote,
    required String memberArtifactsBlock,
    required String structuredResultsBlock,
    required String summarizeArtifactNotes,
    required String pendingNote,
    required String sessionHandoffSuffix,
  }) {
    final dispatchPrefix = lastDispatchNote != null
        ? '$adminSummarizeBase\n\n'
            '[SYSTEM] 你上一轮的派发记录（该 JSON 已从你的消息中隐藏，仅供核对）：$lastDispatchNote'
        : adminSummarizeBase;
    return '$dispatchPrefix'
        '$memberArtifactsBlock'
        '$structuredResultsBlock'
        '$summarizeArtifactNotes'
        '$pendingNote'
        '$sessionHandoffSuffix';
  }

  static String _compact({
    required String adminSummarizeBase,
    String? dispatchUri,
    required String memberArtifactsBlock,
    required String structuredResultsBlock,
    required String summarizeArtifactNotes,
    required String pendingNote,
    required String sessionHandoffSuffix,
    String? resultsUri,
  }) {
    final dispatchPrefix = dispatchUri != null && dispatchUri.trim().isNotEmpty
        ? '$adminSummarizeBase\n\n'
            '[SYSTEM] 派发记录已归档（摘要模式）：$dispatchUri'
            '${resultsUri != null ? '；成员结果见 $resultsUri' : ''}'
        : adminSummarizeBase;
    return '$dispatchPrefix'
        '$memberArtifactsBlock'
        '$structuredResultsBlock'
        '$summarizeArtifactNotes'
        '$pendingNote'
        '$sessionHandoffSuffix';
  }
}
