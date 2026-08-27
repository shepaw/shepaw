import '../../models/message.dart';
import '../session/history_compactor.dart';

/// Packed, member-facing slice of a group transcript.
class GroupMemberHistoryPack {
  final List<Message> kept;
  final List<Message> dropped;
  final String rollupNote;
  final String artifactUriNote;

  const GroupMemberHistoryPack({
    required this.kept,
    required this.dropped,
    required this.rollupNote,
    required this.artifactUriNote,
  });

  bool get droppedAny => dropped.isNotEmpty;

  /// Prefix notes to splice ahead of the kept transcript (rollup + URIs).
  String get truncationPrefix {
    final parts = <String>[
      if (rollupNote.isNotEmpty) rollupNote,
      if (artifactUriNote.isNotEmpty) artifactUriNote,
    ];
    return parts.join('\n');
  }
}

/// Slims group history for **members**. Admin / summarize / abort turns keep
/// the full [adminMaxChars] window in the executor.
///
/// Members already receive this-round brief, dispatch plan, and event digest
/// in the user turn. Replaying ~60k chars of the whole group per member is
/// the dominant token cost; this pack keeps:
/// - a short recent tail (sibling / previous-step output)
/// - the member's own recent replies (so they remember what they already did)
/// - `store://` URIs referenced in omitted turns
class GroupMemberHistory {
  GroupMemberHistory._();

  static const int adminMaxChars = 60000;
  static const int adminKeepRecentCount = 24;
  static const int adminKeepRecentChars = 24000;

  static const int memberMaxChars = 12000;
  static const int memberKeepRecentCount = 8;
  static const int memberKeepRecentChars = 6000;
  static const int memberKeepOwnCount = 6;
  static const int maxOmittedUris = 12;

  /// Same `store://` tokenizer as [GroupOrchestrationService.extractStoreUris].
  static final RegExp storeUriPattern = RegExp(r'store://[^\s\]\[\)\},，;]+');

  /// Admin, loop-close, abort, and closing-summary turns still need the
  /// full group transcript. Member task turns do not.
  static bool needsFullHistory({
    required bool isAdmin,
    required bool isLoopSummarize,
    required bool isAbortSummarize,
    required bool isClosingSummary,
  }) =>
      isAdmin || isLoopSummarize || isAbortSummarize || isClosingSummary;

  static GroupMemberHistoryPack pack({
    required List<Message> messages,
    required String memberId,
    int maxChars = memberMaxChars,
    int keepRecentCount = memberKeepRecentCount,
    int keepRecentChars = memberKeepRecentChars,
    int keepOwnCount = memberKeepOwnCount,
  }) {
    if (messages.isEmpty) {
      return const GroupMemberHistoryPack(
        kept: [],
        dropped: [],
        rollupNote: '',
        artifactUriNote: '',
      );
    }

    final selected = <String>{};

    final recent = <Message>[];
    var recentChars = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final nextCount = recent.length + 1;
      final nextChars = recentChars + m.content.length;
      if (recent.isNotEmpty &&
          (nextCount > keepRecentCount || nextChars > keepRecentChars)) {
        break;
      }
      recent.insert(0, m);
      recentChars = nextChars;
    }
    for (final m in recent) {
      selected.add(m.id);
    }

    var ownKept = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.from.id != memberId) continue;
      if (selected.contains(m.id)) {
        ownKept++;
        continue;
      }
      if (ownKept >= keepOwnCount) break;
      selected.add(m.id);
      ownKept++;
    }

    var kept = messages.where((m) => selected.contains(m.id)).toList();
    kept = _trimToBudget(kept, memberId: memberId, maxChars: maxChars);

    final keptIds = kept.map((m) => m.id).toSet();
    final dropped = messages.where((m) => !keptIds.contains(m.id)).toList();

    return GroupMemberHistoryPack(
      kept: kept,
      dropped: dropped,
      rollupNote: HistoryCompactor.rollupNote(dropped),
      artifactUriNote: omittedArtifactNote(dropped),
    );
  }

  static List<Message> _trimToBudget(
    List<Message> kept, {
    required String memberId,
    required int maxChars,
  }) {
    final result = List<Message>.from(kept);
    var total = result.fold<int>(0, (s, m) => s + m.content.length);
    while (total > maxChars && result.length > 1) {
      final dropAt = result.indexWhere((m) => m.from.id != memberId);
      final idx = dropAt >= 0 ? dropAt : 0;
      total -= result[idx].content.length;
      result.removeAt(idx);
    }
    return result;
  }

  static List<String> extractStoreUris(String text) {
    final uris = <String>[];
    for (final m in storeUriPattern.allMatches(text)) {
      var uri = m.group(0)!.trim();
      while (uri.isNotEmpty &&
          (uri.endsWith(')') ||
              uri.endsWith(']') ||
              uri.endsWith('}') ||
              uri.endsWith(',') ||
              uri.endsWith('，') ||
              uri.endsWith('。') ||
              uri.endsWith(';') ||
              uri.endsWith('.') ||
              uri.endsWith('：'))) {
        uri = uri.substring(0, uri.length - 1);
      }
      if (uri.isNotEmpty && !uris.contains(uri)) uris.add(uri);
    }
    return uris;
  }

  static String omittedArtifactNote(List<Message> dropped) {
    final uris = <String>[];
    for (final m in dropped) {
      for (final uri in extractStoreUris(m.content)) {
        if (!uris.contains(uri)) uris.add(uri);
        if (uris.length >= maxOmittedUris) break;
      }
      if (uris.length >= maxOmittedUris) break;
    }
    if (uris.isEmpty) return '';
    final shown = uris.take(maxOmittedUris).join('、');
    return '[省略消息中引用的产物：$shown]';
  }
}
