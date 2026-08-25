import '../../models/remote_agent.dart';
import '../../models/workflow_models.dart';

/// What the group admin decided at a stage gate.
enum StageGateDecisionType {
  /// [GATE_DECISION: continue] — proceed to the next stage (the default).
  proceed,

  /// [GATE_DECISION: abort] — stop the workflow.
  abort,

  /// [GATE_DECISION: reassign:名字] — hand later pending steps to another member.
  reassign,
}

/// A parsed gate decision. `reassignTarget` is only set when [type] is
/// [StageGateDecisionType.reassign].
class StageGateDecision {
  final StageGateDecisionType type;
  final String? reassignTarget;

  const StageGateDecision._(this.type, this.reassignTarget);

  static const StageGateDecision proceed =
      StageGateDecision._(StageGateDecisionType.proceed, null);
  static const StageGateDecision abort =
      StageGateDecision._(StageGateDecisionType.abort, null);
  static StageGateDecision reassign(String target) =>
      StageGateDecision._(StageGateDecisionType.reassign, target);

  bool get isProceed => type == StageGateDecisionType.proceed;
  bool get isAbort => type == StageGateDecisionType.abort;
  bool get isReassign => type == StageGateDecisionType.reassign;
}

final RegExp _gateDecisionRe = RegExp(
  r'\[GATE_DECISION:\s*(continue|abort|reassign)\s*(?::\s*(.+?))?\s*\]',
  caseSensitive: false,
);

/// Extracts the first `[GATE_DECISION: ...]` line from the admin's reply.
///
/// Returns null when no valid decision is present — callers treat that as
/// "proceed" so an unparseable gate reply never blocks the workflow.
/// A `reassign` without a target name also yields null.
StageGateDecision? parseGateDecision(String text) {
  if (text.isEmpty) return null;
  final m = _gateDecisionRe.firstMatch(text);
  if (m == null) return null;
  switch (m.group(1)!.toLowerCase()) {
    case 'continue':
      return StageGateDecision.proceed;
    case 'abort':
      return StageGateDecision.abort;
    case 'reassign':
      final target = m.group(2)?.trim();
      if (target == null || target.isEmpty) return null;
      return StageGateDecision.reassign(target);
    default:
      return null;
  }
}

/// Renders one step's outcome for the gate prompt.
String renderStageGateStepLine(WorkflowStepExecution step) {
  final idx = '阶段${step.stageIndex + 1}/步骤${step.stepIndex + 1}';
  final name = step.agentName.isEmpty ? '(未指派)' : step.agentName;
  switch (step.status) {
    case StepExecutionStatus.completed:
      final summary = (step.outputSummary ?? '').trim().replaceAll('\n', ' ');
      return summary.isEmpty
          ? '$idx · 成员$name · ✅ 完成'
          : '$idx · 成员$name · ✅ 完成 · $summary';
    case StepExecutionStatus.failed:
      final err = (step.errorMessage ?? '').trim().replaceAll('\n', ' ');
      return err.isEmpty
          ? '$idx · 成员$name · ❌ 失败'
          : '$idx · 成员$name · ❌ 失败 · $err';
    case StepExecutionStatus.skipped:
      return '$idx · 成员$name · ⏭ 跳过';
    default:
      return '$idx · 成员$name · ⏳ ${step.status.dbValue}';
  }
}

/// Builds the admin's stage-gate turn content.
///
/// [stageIndex] is 1-based for display (stage N of the workflow), matching the
/// step-line rendering in [renderStageGateStepLine].
String buildStageGatePrompt({
  required String groupName,
  required int stageIndex,
  required String stageName,
  required String nextStageName,
  required List<String> resultLines,
  required List<RemoteAgent> currentMembers,
}) {
  final stageLabel = stageName.isEmpty ? '阶段 $stageIndex' : '阶段 $stageIndex「$stageName」';
  final nextLabel = nextStageName.isEmpty ? '阶段 ${stageIndex + 1}' : '阶段 ${stageIndex + 1}「$nextStageName」';

  final buffer = StringBuffer()
    ..writeln('【阶段门闸 · 管理员决策】')
    ..writeln()
    ..writeln('群聊「$groupName」的 $stageLabel 已执行完毕，即将进入 $nextLabel。')
    ..writeln('请审阅本阶段结果并决策是否继续：')
    ..writeln();
  if (resultLines.isEmpty) {
    buffer.writeln('（本阶段无步骤结果）');
  } else {
    for (final line in resultLines) {
      buffer.writeln('• $line');
    }
  }
  buffer.writeln();
  buffer.writeln(
      '当前群成员（${currentMembers.length} 人）：${currentMembers.map((a) => a.name).join('、')}');
  buffer.writeln();
  buffer.writeln('请从以下选项中选择，并输出一行结构化决策（其余内容可自由说明你的考量）：');
  buffer.writeln('1. [GATE_DECISION: continue] — 继续下一阶段（默认）');
  buffer.writeln('2. [GATE_DECISION: abort] — 中止工作流');
  buffer.writeln('3. [GATE_DECISION: reassign:新成员名] — 后续未开始步骤改派给指定成员');
  buffer.writeln('必须且只能输出一行 [GATE_DECISION: ...]，直接给出决策即可。');
  return buffer.toString();
}

/// Custom system prompt for the gate turn — reinforces the "no tools" rule on
/// top of the base admin prompt and requires the single structured decision
/// line the executor will consume.
const String stageGateSystemPrompt = '本次消息是工作流阶段的自动门闸把关。'
    '你必须基于本阶段结果明确决策，并在回复中输出且仅输出一行 [GATE_DECISION: ...]，'
    '取值为 continue、abort 或 reassign:成员名（成员名必须是当前群成员中的一人）。'
    '不要调用 group_dispatch、group_finish、group_mention、shepaw 等任何工具，'
    '不要输出 ```json 派发块，不要调用任何 UI 工具。除决策行外，可用几句话说明你的考量。';
