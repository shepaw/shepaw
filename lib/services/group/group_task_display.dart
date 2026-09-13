import '../../models/group_task.dart';
import '../../storage/artifact_service.dart';
import 'group_member_history.dart';

/// Read-side helpers for group task UI.
///
/// Does not write task.json / index.json / archive.md. Orchestration keeps
/// the raw [GroupTask.userGoal] and compiled archive as the source of truth.
class GroupTaskDisplay {
  GroupTaskDisplay._();

  static const listTitleMaxChars = 80;
  static const detailTitleMaxChars = 80;

  static final _whitespace = RegExp(r'\s+');
  static final _taskRecordFile = RegExp(
    r'/shared/tasks/[^/]+/'
    r'(task\.json|requirement\.md|plan\.md|plan\.json|results\.json|archive\.md)$',
  );

  /// List / app-bar label from the user's original message.
  ///
  /// Keeps mentions and later sentences. Only collapses whitespace so a
  /// multi-line chat message fits one title, then truncates if still long.
  static String title(
    String userGoal, {
    String fallback = '',
    int maxChars = listTitleMaxChars,
  }) {
    var text = userGoal.trim();
    if (text.isEmpty) return fallback;
    text = text.replaceAll(_whitespace, ' ').trim();
    if (text.isEmpty) return fallback;
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
