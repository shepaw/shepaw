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
    this.hasOrchestrationSignal = false,
  });

  bool get hasDispatch => steps.isNotEmpty;

  static const empty = GroupTurnResult();
}
