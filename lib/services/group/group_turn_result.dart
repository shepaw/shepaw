import '../../models/mention_entry.dart';
import 'group_dispatch_parser.dart';

/// Structured outcome of one group-agent turn (especially admin orchestration).
///
/// Prefer tool-captured [steps] / finish signals over parsing ```json``` from
/// free-form chat text.
class GroupTurnResult {
  final String content;
  final List<DispatchStep> steps;
  final bool wantsContinue;
  final bool isDone;
  final bool isPause;
  final String? parseError;
  final List<String> unresolvedNames;

  /// Structured mentions the agent declared in its reply (`group_mention`
  /// tool args / reply metadata, notify: true = activate) plus any legacy
  /// JSON dispatch steps, unified here so orchestration drives
  /// member-to-member collaboration from one protocol. Text `@name` is
  /// display-only and never parsed.
  final List<MentionEntry> mentions;

  /// Declared mention names that matched no group member.
  final List<String> unresolvedMentionNames;

  /// True when the model called `group_dispatch` or `group_finish`.
  final bool hasOrchestrationSignal;

  const GroupTurnResult({
    this.content = '',
    this.steps = const [],
    this.wantsContinue = false,
    this.isDone = false,
    this.isPause = false,
    this.parseError,
    this.unresolvedNames = const [],
    this.mentions = const [],
    this.unresolvedMentionNames = const [],
    this.hasOrchestrationSignal = false,
  });

  bool get hasDispatch => steps.isNotEmpty;

  static const empty = GroupTurnResult();
}
