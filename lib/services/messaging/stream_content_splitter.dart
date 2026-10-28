import '../../utils/progress_content_utils.dart';

/// Splits agent stream text into progress (thinking/tools) vs answer.
///
/// Driven by `ui.messageMetadata` / `agent_metadata`:
/// - `collapsible: true` → subsequent chunks go to [progressContent]
/// - `collapsible: false` → subsequent chunks go to [answerContent]
///
/// If upstream already split (`progress_content` in metadata), chunks pass
/// through to [answerContent] without re-diverting.
class StreamContentSplitter {
  bool divertToProgress = false;
  bool alreadySplitUpstream = false;
  String progressContent = '';
  String answerContent = '';
  String? progressTitle;
  bool autoCollapse = true;

  /// 结构化步骤。来源有两种：整份的 `progress_steps`（直接覆盖），
  /// 或每帧的 `progress_step_updates`（按 id 合并）。思考正文不走线上，
  /// 由 [onChunk] 往当前步骤里续写。
  ///
  /// 对外发布的永远是新建的列表和新建的 Map，已经发出去的快照不会再被改动。
  List<Map<String, dynamic>>? progressSteps;

  /// 步骤流不是从回合开头收到的（比如断线后接着收），拼不出完整列表时置位，
  /// 之后一律回退到 `progress_content` 的老渲染。
  bool stepsBroken = false;

  /// Apply a metadata frame. Returns a map suitable for merging into message
  /// metadata (includes live [progressContent] when non-empty).
  Map<String, dynamic> onMetadata(Map<String, dynamic> data) {
    final canStartSteps = progressSteps == null &&
        progressContent.isEmpty &&
        !alreadySplitUpstream &&
        !stepsBroken;
    final fullSteps = data['progress_steps'];
    if (fullSteps is List && fullSteps.isNotEmpty) {
      progressSteps = [
        for (final item in fullSteps)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    }
    final stepUpdates = data['progress_step_updates'];
    if (stepUpdates is List && stepUpdates.isNotEmpty) {
      if (progressSteps != null || canStartSteps) {
        for (final item in stepUpdates) {
          if (item is Map) _upsertStep(Map<String, dynamic>.from(item));
        }
      } else {
        stepsBroken = true;
      }
    }
    if (data.containsKey('progress_content')) {
      alreadySplitUpstream = true;
      divertToProgress = false;
      final existing = data['progress_content'];
      if (existing is String && existing.isNotEmpty) {
        progressContent = capProgressContent(existing);
      }
    }

    if (!alreadySplitUpstream) {
      if (data['collapsible'] == true) {
        divertToProgress = true;
        final title = data['collapsible_title'] as String?;
        final toolStatus = data['tool_status'] as String?;
        final plan = data['plan'];
        if (plan is List && plan.isNotEmpty) {
          progressTitle = (title != null && title.isNotEmpty) ? title : 'Plan';
          final planLines = _formatPlanEntries(plan);
          if (planLines.isNotEmpty) {
            if (progressContent.isNotEmpty &&
                !progressContent.endsWith('\n')) {
              progressContent += '\n';
            }
            progressContent += planLines;
          }
        } else if (title != null && title.isNotEmpty) {
          progressTitle = title;
          // Record non-thinking tool step titles into progressContent so that
          // silent tool-heavy phases still show a live step log in the
          // collapsible block instead of appearing frozen.
          if (title != 'Thinking' && title != 'Details') {
            final suffix = _toolStatusSuffix(toolStatus);
            final baseStep = '- $title\n';
            final finalStep =
                suffix != null ? '- $title $suffix\n' : baseStep;
            if (suffix != null && progressContent.endsWith(baseStep)) {
              progressContent = progressContent.substring(
                    0,
                    progressContent.length - baseStep.length,
                  ) +
                  finalStep;
            } else if (!progressContent.endsWith(finalStep) &&
                !progressContent.endsWith(baseStep)) {
              if (progressContent.isNotEmpty &&
                  !progressContent.endsWith('\n')) {
                progressContent += '\n';
              }
              progressContent += finalStep;
            }
          }
        }
        if (data.containsKey('auto_collapse')) {
          autoCollapse = data['auto_collapse'] == true;
        }
      } else if (data.containsKey('collapsible')) {
        divertToProgress = false;
      }
    }

    final out = Map<String, dynamic>.from(data);
    out.remove('progress_step_updates');
    if (progressSteps != null && !stepsBroken) {
      out['progress_steps'] = List<Map<String, dynamic>>.of(progressSteps!);
    } else {
      out.remove('progress_steps');
    }
    if (progressContent.isNotEmpty) {
      out['progress_content'] = progressContent;
      out['collapsible'] = true;
      out['collapsible_title'] =
          progressTitle ?? (out['collapsible_title'] as String?) ?? 'Details';
      out['auto_collapse'] = autoCollapse;
    } else if (!alreadySplitUpstream && divertToProgress) {
      // Tool/thinking phase started, but no progress text has arrived yet.
      // Keep the title for live progress indicator without marking the whole
      // message body as legacy collapsible.
      out.remove('collapsible');
      if (progressTitle != null && progressTitle!.isNotEmpty) {
        out['collapsible_title'] = progressTitle;
      }
      out['auto_collapse'] = autoCollapse;
    } else if (data['collapsible'] == false) {
      // Answer section — don't keep whole-message collapsible.
      out['collapsible'] = false;
    }
    return out;
  }

  /// Route a text chunk. Returns the answer delta (empty when diverted to
  /// progress). Progress updates are exposed via [progressMetadataDelta].
  String onChunk(String chunk) {
    if (!alreadySplitUpstream && divertToProgress) {
      progressContent = appendProgressContent(progressContent, chunk);
      _appendToCurrentStep(chunk);
      return '';
    }
    answerContent += chunk;
    return chunk;
  }

  /// Metadata patch after a progress chunk (empty if nothing to publish).
  Map<String, dynamic>? progressMetadataDelta() {
    if (progressContent.isEmpty) return null;
    return {
      'progress_content': progressContent,
      'collapsible': true,
      'collapsible_title': progressTitle ?? 'Details',
      'auto_collapse': autoCollapse,
      if (_publishableSteps() case final steps?) 'progress_steps': steps,
    };
  }

  List<Map<String, dynamic>>? _publishableSteps() {
    final steps = progressSteps;
    if (steps == null || stepsBroken) return null;
    return List<Map<String, dynamic>>.of(steps);
  }

  void _upsertStep(Map<String, dynamic> update) {
    final id = update['id'];
    if (id is! String || id.isEmpty) return;
    final steps = progressSteps ??= <Map<String, dynamic>>[];
    final index = steps.indexWhere((s) => s['id'] == id);
    if (index == -1) {
      steps.add(update);
    } else {
      // 更新不带正文；正文是本地续写出来的，合并时不能丢。
      steps[index] = {...steps[index], ...update};
    }
  }

  void _appendToCurrentStep(String chunk) {
    final steps = progressSteps;
    if (steps == null || steps.isEmpty || stepsBroken) return;
    final last = steps.last;
    // 计划的正文来自步骤更新，不靠 chunk。
    if (last['type'] == 'plan') return;
    final body = last['body'];
    steps[steps.length - 1] = {
      ...last,
      'body': appendProgressContent(body is String ? body : '', chunk),
    };
  }

  /// Final metadata to persist alongside the answer.
  Map<String, dynamic> finalProgressMetadata() {
    // 回合结束了还标着进行中的步骤（有的引擎不发终态更新）记为完成。
    final steps = _publishableSteps()
        ?.map(
            (s) => s['status'] == 'running' ? {...s, 'status': 'completed'} : s)
        .toList();
    if (progressContent.isEmpty) {
      return steps == null ? const {} : {'progress_steps': steps};
    }
    return {
      'progress_content': progressContent,
      'collapsible': true,
      'collapsible_title': progressTitle ?? 'Details',
      'auto_collapse': autoCollapse,
      if (steps != null) 'progress_steps': steps,
    };
  }

  static String? _toolStatusSuffix(String? status) {
    switch (status) {
      case 'completed':
        return '✓';
      case 'failed':
      case 'cancelled':
      case 'rejected':
        return '✗';
      default:
        return null;
    }
  }

  static String _formatPlanEntries(List<dynamic> entries) {
    final buf = StringBuffer();
    for (final raw in entries) {
      if (raw is! Map) continue;
      final content = (raw['content'] as String?)?.trim() ?? '';
      if (content.isEmpty) continue;
      final status = raw['status'] as String?;
      final marker = status == 'completed'
          ? '[x]'
          : status == 'in_progress'
              ? '[>]'
              : '[ ]';
      buf.writeln('- $marker $content');
    }
    return buf.toString();
  }
}
