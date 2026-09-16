import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import '../../storage/store_uri_reader.dart';
import '../logger_service.dart';
import 'group_orchestration_features.dart';
import 'group_result_writer.dart';

/// Admin loop-summarize: pull readable excerpts from member artifact URIs
/// (Phase 0 D — admin no longer relies on 240-char truncated summaries alone).
class GroupAdminArtifactPrefill {
  GroupAdminArtifactPrefill._();

  static const _tag = 'GroupAdminArtifactPrefill';

  /// Max distinct artifacts to read per summarize turn.
  static const maxArtifacts = 3;

  /// Max bytes per artifact body (UTF-8).
  static const maxBytesPerArtifact = 8192;

  static Future<String> loadPrefillBlock({
    required String groupId,
    required String orchestrationId,
    int? round,
  }) async {
    if (!GroupOrchestrationFeatures.adminArtifactPrefill) return '';
    try {
      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (results == null || results.members.isEmpty) return '';
      final targets = _selectMembers(results.members, round: round);
      if (targets.isEmpty) return '';

      final lines = <String>['【成员产物摘录 · store read】'];
      var readCount = 0;
      for (final member in targets) {
        if (readCount >= maxArtifacts) break;
        for (final uri in member.artifactUris) {
          if (readCount >= maxArtifacts) break;
          final trimmed = uri.trim();
          if (trimmed.isEmpty) continue;
          final excerpt = await _readExcerpt(trimmed);
          readCount++;
          lines.add('- ${member.agentName}: `$trimmed`');
          lines.add(excerpt.isEmpty ? '  （读取失败或为空）' : excerpt);
        }
      }
      if (lines.length <= 1) return '';
      return '\n\n${lines.join('\n')}';
    } catch (e) {
      LoggerService().debug(
        'artifact prefill failed: $groupId/$orchestrationId — $e',
        tag: _tag,
      );
      return '';
    }
  }

  @visibleForTesting
  static List<GroupTaskMemberResult> selectMembersForTest(
    List<GroupTaskMemberResult> members, {
    int? round,
  }) =>
      _selectMembers(members, round: round);

  @visibleForTesting
  static bool needsPrefillForTest(GroupTaskMemberResult member) =>
      _needsPrefill(member);

  /// Prefer members whose summary was clipped or points at an artifact URI.
  static List<GroupTaskMemberResult> _selectMembers(
    List<GroupTaskMemberResult> members, {
    int? round,
  }) {
    final filtered = round == null
        ? members
        : members.where((m) => m.round == round).toList();
    if (filtered.isEmpty) return const [];

    final withArtifacts =
        filtered.where((m) => m.artifactUris.isNotEmpty).toList();
    if (withArtifacts.isEmpty) return const [];

    withArtifacts.sort((a, b) {
      final aNeeds = _needsPrefill(a) ? 0 : 1;
      final bNeeds = _needsPrefill(b) ? 0 : 1;
      if (aNeeds != bNeeds) return aNeeds.compareTo(bNeeds);
      return a.agentName.compareTo(b.agentName);
    });
    return withArtifacts;
  }

  static bool _needsPrefill(GroupTaskMemberResult member) {
    if (member.artifactUris.isEmpty) return false;
    final summary = member.summary;
    if (summary.contains('全文见')) return true;
    if (summary.length >= GroupResultWriter.maxSummaryChars - 1) return true;
    for (final uri in member.artifactUris) {
      if (summary.contains(uri)) return true;
    }
    return member.taskStatus == GroupTaskMemberResult.statusDone &&
        summary.length < 40;
  }

  static Future<String> _readExcerpt(String uri) async {
    try {
      final bytes = await StoreUriReader.instance.read(uri);
      final slice = bytes.length > maxBytesPerArtifact
          ? bytes.sublist(0, maxBytesPerArtifact)
          : bytes;
      var text = utf8.decode(slice, allowMalformed: true).trim();
      if (bytes.length > maxBytesPerArtifact) {
        text = '$text…';
      }
      // Indent for readability inside admin prompt.
      return text
          .split('\n')
          .map((l) => '  $l')
          .join('\n');
    } catch (e) {
      LoggerService().debug('read artifact $uri failed: $e', tag: _tag);
      return '  （读取失败：$e）';
    }
  }
}
