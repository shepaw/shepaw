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
        progressContent = existing;
      }
    }

    if (!alreadySplitUpstream) {
      if (data['collapsible'] == true) {
        divertToProgress = true;
        final title = data['collapsible_title'] as String?;
        if (title != null && title.isNotEmpty) {
          progressTitle = title;
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
      progressContent += chunk;
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
}
