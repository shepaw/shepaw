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

  /// Apply a metadata frame. Returns a map suitable for merging into message
  /// metadata (includes live [progressContent] when non-empty).
  Map<String, dynamic> onMetadata(Map<String, dynamic> data) {
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
    };
  }

  /// Final metadata to persist alongside the answer.
  Map<String, dynamic> finalProgressMetadata() {
    if (progressContent.isEmpty) return const {};
    return {
      'progress_content': progressContent,
      'collapsible': true,
      'collapsible_title': progressTitle ?? 'Details',
      'auto_collapse': autoCollapse,
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
