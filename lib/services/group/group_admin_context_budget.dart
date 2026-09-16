import 'group_member_delivery.dart';
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

  static const int compactGroupMemoryChars = 800;

  /// Admin first turn / abort: merge context blocks with char budget (Phase I).
  static String assembleFirstAdminTurnContent({
    required String bundledContent,
    required String groupMemoryBlock,
    String? groupMemoryUri,
    required String crossTaskNotes,
    required String artifactNotes,
    required String artifactCompactNotes,
    String? requirementUri,
    String? userGoal,
  }) {
    String joinParts(String base, String memory, String cross, String artifacts) {
      var out = base;
      if (memory.isNotEmpty) out = '$out\n\n$memory';
      if (cross.isNotEmpty) out = '$out\n\n$cross';
      if (artifacts.isNotEmpty) out = '$out$artifacts';
      return out;
    }

    if (budgetChars <= 0) {
      return joinParts(
        bundledContent,
        groupMemoryBlock,
        crossTaskNotes,
        artifactNotes,
      );
    }

    final full = joinParts(
      bundledContent,
      groupMemoryBlock,
      crossTaskNotes,
      artifactNotes,
    );
    if (full.length <= budgetChars) return full;

    final memoryCompact =
        _compactGroupMemoryBlock(groupMemoryBlock, groupMemoryUri);
    final compact = joinParts(
      bundledContent,
      memoryCompact,
      crossTaskNotes,
      artifactCompactNotes,
    );
    if (compact.length <= budgetChars) return compact;

    final goal = (userGoal ?? bundledContent).trim();
    final shortBase = GroupMemberDelivery.buildAdminLoopSummarizePrefix(
      userGoal: goal,
      requirementUri: requirementUri,
      round: 1,
    );
    final parts = <String>[shortBase];
    if (groupMemoryUri != null && groupMemoryUri.trim().isNotEmpty) {
      parts.add('[群记忆] 全文见 `$groupMemoryUri`');
    }
    final prevOnly = _previousTaskSectionOnly(crossTaskNotes);
    if (prevOnly.isNotEmpty) parts.add(prevOnly);
    if (artifactCompactNotes.isNotEmpty) {
      parts.add(artifactCompactNotes.trim());
    }
    final minimal = parts.join('\n\n');
    if (minimal.length <= budgetChars) return minimal;

    return '[SYSTEM] 上下文已超预算（摘要模式）。'
        '${requirementUri != null ? ' 定稿需求 `$requirementUri`；' : ''}'
        '${groupMemoryUri != null ? ' 群记忆 `$groupMemoryUri`；' : ''}'
        ' Scope Card 见系统提示。\n'
        '$shortBase';
  }

  /// First admin turn with recon gate note appended (budget includes suffix).
  static String buildFirstTurnWithGateNote({
    required String effectiveContent,
    required String gateNote,
  }) {
    final note = gateNote.trim();
    if (note.isEmpty) return effectiveContent;
    var combined = '$effectiveContent\n\n$note';
    if (budgetChars <= 0 || combined.length <= budgetChars) return combined;
    final overhead = note.length + 2;
    final maxBase = (budgetChars - overhead).clamp(200, budgetChars);
    if (effectiveContent.length > maxBase) {
      combined = '${effectiveContent.substring(0, maxBase)}…\n\n$note';
    }
    return combined;
  }

  static String _compactGroupMemoryBlock(String block, String? uri) {
    if (block.isEmpty) return '';
    const marker = '[群历史任务总结（shared/memory/latest.md）]\n';
    if (!block.startsWith(marker)) {
      return _truncateBlock(block, compactGroupMemoryChars, uri);
    }
    final body = block.substring(marker.length).trim();
    if (body.isEmpty) return block;
    final clipped = body.length <= compactGroupMemoryChars
        ? body
        : '${body.substring(0, compactGroupMemoryChars)}…';
    final uriLine = (uri != null && uri.trim().isNotEmpty)
        ? '\n（全文见 `$uri`）'
        : '';
    return '$marker$clipped$uriLine';
  }

  static String _truncateBlock(String block, int max, String? uri) {
    if (block.length <= max) return block;
    final uriLine =
        (uri != null && uri.trim().isNotEmpty) ? '\n（全文见 `$uri`）' : '';
    return '${block.substring(0, max)}…$uriLine';
  }

  static String _previousTaskSectionOnly(String crossTaskNotes) {
    final trimmed = crossTaskNotes.trim();
    if (trimmed.isEmpty) return '';
    const marker = '[上一任务摘要]';
    final idx = trimmed.indexOf(marker);
    if (idx < 0) return '';
    final rest = trimmed.substring(idx);
    const nextMarker = '\n\n[当前任务定稿需求';
    final end = rest.indexOf(nextMarker);
    return end >= 0 ? rest.substring(0, end).trim() : rest;
  }

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
    String artifactPrefillBlock = '',
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
        artifactPrefillBlock: artifactPrefillBlock,
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
      artifactPrefillBlock: artifactPrefillBlock,
    );
    if (full.length <= budgetChars) return full;

    // Compact mode drops artifact prefill to save tokens (URIs remain in results).
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
    String artifactPrefillBlock = '',
  }) {
    final dispatchPrefix = lastDispatchNote != null
        ? '$adminSummarizeBase\n\n'
            '[SYSTEM] 你上一轮的派发记录（该 JSON 已从你的消息中隐藏，仅供核对）：$lastDispatchNote'
        : adminSummarizeBase;
    return '$dispatchPrefix'
        '$memberArtifactsBlock'
        '$structuredResultsBlock'
        '$artifactPrefillBlock'
        '$summarizeArtifactNotes'
        '$pendingNote'
        '$sessionHandoffSuffix';
  }

  /// Admin nudge / stall / wake turns: short task prefix + system note only.
  static String buildNudgeContent({
    required String adminSummarizeBase,
    required String systemNote,
  }) {
    final note = systemNote.trim();
    if (note.isEmpty) return adminSummarizeBase;
    var content = '$adminSummarizeBase\n\n$note';
    if (budgetChars <= 0 || content.length <= budgetChars) return content;
    final overhead = note.length + 2;
    final maxBase = (budgetChars - overhead).clamp(200, budgetChars);
    if (adminSummarizeBase.length > maxBase) {
      content =
          '${adminSummarizeBase.substring(0, maxBase)}…\n\n$note';
    }
    return content;
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
