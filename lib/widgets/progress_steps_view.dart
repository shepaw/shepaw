import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/progress_step.dart';

/// 气泡上方的多层折叠区：摘要行 → 步骤列表 → 单步详情（思考正文）。
///
/// 数据来自主机下发的 `metadata.progress_steps`。摘要行流式时显示当前动作，
/// 结束后收成「思考 3 秒 · 5 次工具调用」；展开是逐行的步骤，带有正文的步骤
/// （目前是思考）可以再点开。
class ProgressStepsView extends StatefulWidget {
  final List<ProgressStep> steps;

  /// 折叠区所属的这一段还在进行中（决定摘要行文案和转圈）。
  final bool isStreaming;
  final bool hasAnswer;
  final bool autoCollapse;
  final bool isMyMessage;

  /// 渲染步骤正文（思考文字）。由气泡传入，沿用气泡自己的 markdown 样式。
  final Widget Function(BuildContext context, String body, bool streaming)
      bodyBuilder;

  const ProgressStepsView({
    super.key,
    required this.steps,
    required this.isStreaming,
    required this.hasAnswer,
    required this.autoCollapse,
    required this.isMyMessage,
    required this.bodyBuilder,
  });

  /// 摘要行文案。独立成纯函数，方便单测。
  static String headerText(
    AppLocalizations l10n,
    List<ProgressStep> steps, {
    required bool streaming,
  }) {
    if (streaming) {
      ProgressStep? running;
      for (final step in steps.reversed) {
        if (step.isRunning) {
          running = step;
          break;
        }
      }
      if (running == null) return l10n.progress_steps_working;
      if (running.type == ProgressStepType.thought) {
        return l10n.progress_steps_thinking;
      }
      final summary = running.summary;
      return summary == null
          ? '${running.title}…'
          : '${running.title}: $summary';
    }

    var thoughtSeconds = 0;
    var hasThought = false;
    var tools = 0;
    var failed = 0;
    for (final step in steps) {
      if (step.omitted > 0) {
        tools += step.omitted;
        continue;
      }
      switch (step.type) {
        case ProgressStepType.thought:
          hasThought = true;
          thoughtSeconds += step.duration?.inSeconds ?? 0;
        case ProgressStepType.tool:
          tools++;
          if (step.status == ProgressStepStatus.failed) failed++;
        case ProgressStepType.plan:
          break;
      }
    }
    final parts = <String>[
      if (hasThought)
        thoughtSeconds >= 1
            ? l10n.progress_steps_thought_for(thoughtSeconds)
            : l10n.progress_steps_thought,
      if (tools > 0) l10n.progress_steps_tool_calls(tools),
      if (failed > 0) l10n.progress_steps_failed(failed),
    ];
    if (parts.isEmpty) return steps.isEmpty ? '' : steps.first.title;
    return parts.join(' · ');
  }

  static String formatDuration(Duration d) {
    final seconds = d.inSeconds;
    if (seconds < 1) return '';
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  static IconData iconFor(ProgressStep step) {
    if (step.type == ProgressStepType.thought) return Icons.psychology_outlined;
    if (step.type == ProgressStepType.plan) return Icons.checklist;
    switch (step.toolKind) {
      case 'read':
        return Icons.description_outlined;
      case 'edit':
        return Icons.edit_outlined;
      case 'delete':
        return Icons.delete_outline;
      case 'move':
        return Icons.drive_file_move_outlined;
      case 'search':
        return Icons.search;
      case 'execute':
        return Icons.terminal;
      case 'fetch':
        return Icons.public;
      case 'think':
        return Icons.psychology_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  @override
  State<ProgressStepsView> createState() => _ProgressStepsViewState();
}

class _ProgressStepsViewState extends State<ProgressStepsView> {
  late bool _expanded;
  bool _userToggled = false;
  final Map<String, bool> _stepOverride = {};

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming && !widget.hasAnswer;
  }

  @override
  void didUpdateWidget(covariant ProgressStepsView old) {
    super.didUpdateWidget(old);
    if (_userToggled || !widget.autoCollapse) return;
    final answerStarted = widget.hasAnswer && !old.hasAnswer;
    final finished = old.isStreaming && !widget.isStreaming;
    if ((answerStarted || finished) && _expanded) {
      setState(() => _expanded = false);
    }
  }

  bool _stepExpanded(ProgressStep step) {
    final override = _stepOverride[step.id];
    if (override != null) return override;
    // 正在流出来的思考默认摊开，看得到它在想什么；结束后自己收起。
    return widget.isStreaming &&
        step.isRunning &&
        step.type == ProgressStepType.thought;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final headerColor =
        widget.isMyMessage ? Colors.white70 : onSurface.withValues(alpha: 0.54);
    final chevronColor =
        widget.isMyMessage ? Colors.white60 : onSurface.withValues(alpha: 0.45);
    final header = ProgressStepsView.headerText(
      l10n,
      widget.steps,
      streaming: widget.isStreaming,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => setState(() {
            _userToggled = true;
            _expanded = !_expanded;
          }),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: EdgeInsets.only(bottom: _expanded ? 4 : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: chevronColor,
                ),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(
                    header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: headerColor,
                    ),
                  ),
                ),
                if (widget.isStreaming) ...[
                  const SizedBox(width: 6),
                  _Spinner(color: headerColor),
                ],
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final step in widget.steps)
                  _StepRow(
                    step: step,
                    l10n: l10n,
                    color: headerColor,
                    expanded: _stepExpanded(step),
                    streaming: widget.isStreaming && step.isRunning,
                    bodyBuilder: widget.bodyBuilder,
                    onToggle: step.hasBody
                        ? () => setState(
                              () =>
                                  _stepOverride[step.id] = !_stepExpanded(step),
                            )
                        : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final ProgressStep step;
  final AppLocalizations l10n;
  final Color color;
  final bool expanded;
  final bool streaming;
  final VoidCallback? onToggle;
  final Widget Function(BuildContext, String, bool) bodyBuilder;

  const _StepRow({
    required this.step,
    required this.l10n,
    required this.color,
    required this.expanded,
    required this.streaming,
    required this.bodyBuilder,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final failed = step.status == ProgressStepStatus.failed;
    final title = step.omitted > 0
        ? l10n.progress_steps_earlier(step.omitted)
        : step.title;
    final duration = step.duration == null
        ? ''
        : ProgressStepsView.formatDuration(step.duration!);
    final textStyle = TextStyle(fontSize: 12, color: color);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(ProgressStepsView.iconFor(step), size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: title,
                    style: textStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (step.summary != null)
                    TextSpan(text: '  ${step.summary}', style: textStyle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (duration.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(duration, style: textStyle.copyWith(fontSize: 11)),
          ],
          const SizedBox(width: 6),
          if (step.isRunning)
            _Spinner(color: color)
          else if (failed)
            const Icon(Icons.error_outline, size: 14, color: Colors.redAccent)
          else
            Icon(Icons.check, size: 14, color: color),
          if (onToggle != null) ...[
            const SizedBox(width: 2),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: color,
            ),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        onToggle == null ? row : InkWell(onTap: onToggle, child: row),
        if (expanded && step.hasBody)
          Container(
            margin: const EdgeInsets.only(left: 6, bottom: 4),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: color.withValues(alpha: 0.4), width: 2),
              ),
            ),
            child: bodyBuilder(context, step.body!, streaming),
          ),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  final Color color;
  const _Spinner({required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
}
