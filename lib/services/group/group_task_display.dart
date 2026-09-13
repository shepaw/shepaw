import '../../models/group_task.dart';
import '../../storage/artifact_service.dart';
import 'group_member_history.dart';

/// Read-side helpers for group task UI.
///
/// Does not write task.json / index.json / archive.md. Orchestration keeps
/// the raw [GroupTask.userGoal] and compiled archive as the source of truth.
class GroupTaskDisplay {
  GroupTaskDisplay._();

  static const listTitleMaxChars = 36;
  static const detailTitleMaxChars = 72;

  static final _whitespace = RegExp(r'\s+');
  static final _leadingMentions = RegExp(
    r'^(?:@[\w\u00c0-\u024f\u4e00-\u9fff.\-]+\s+)+',
    unicode: true,
  );
  static final _sentenceEnd = RegExp(r'[。！？!?]');
  static final _taskRecordFile = RegExp(
    r'/shared/tasks/[^/]+/'
    r'(task\.json|requirement\.md|plan\.md|plan\.json|results\.json|archive\.md)$',
  );

  /// Short label for lists / app bars. Never invents a new stored title.
  static String title(
    String userGoal, {
    String fallback = '',
    int maxChars = listTitleMaxChars,
  }) {
    var text = userGoal.trim();
    if (text.isEmpty) return fallback;
    text = text.replaceAll(_whitespace, ' ').trim();
    text = text.replaceFirst(_leadingMentions, '').trim();
    if (text.isEmpty) return fallback;

    final end = _sentenceEnd.firstMatch(text);
    if (end != null && end.start >= 4) {
      text = text.substring(0, end.end).trim();
    }

    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars).trimRight()}…';
  }

  /// Deliverable URIs only — skips task record files compiled into archive.md.
  static List<String> artifactUris({
    GroupTaskResults? results,
    String? archive,
  }) {
    final seen = <String>{};
    final out = <String>[];
    void add(String raw) {
      final uri = raw.trim();
      if (uri.isEmpty || !uri.startsWith('store://')) return;
      if (_taskRecordFile.hasMatch(uri)) return;
      if (seen.add(uri)) out.add(uri);
    }

    if (results != null) {
      for (final member in results.members) {
        for (final uri in member.artifactUris) {
          add(uri);
        }
      }
    }
    if (archive != null && archive.contains('store://')) {
      for (final uri in GroupMemberHistory.extractStoreUris(archive)) {
        add(uri);
      }
    }
    return out;
  }

  static String artifactLabel(String uri) {
    final parsed = ArtifactUri.tryParse(uri);
    if (parsed != null && parsed.filename.isNotEmpty) return parsed.filename;
    final slash = uri.lastIndexOf('/');
    if (slash >= 0 && slash < uri.length - 1) {
      final last = uri.substring(slash + 1);
      try {
        return Uri.decodeComponent(last);
      } catch (_) {
        return last;
      }
    }
    return uri;
  }
}
