import '../../models/group_task.dart';
import '../../models/group_task_artifact.dart';
import '../../storage/group_workspace_service.dart';
import '../logger_service.dart';
import 'group_member_history.dart';
import 'group_orchestration_features.dart';
import 'group_task_display.dart';

/// 任务级产物登记与自动聚合。
class GroupArtifactRegistry {
  GroupArtifactRegistry._();

  static Future<GroupTaskArtifactPlan?> publishPlan({
    required String groupId,
    required String orchestrationId,
    required String storeTaskId,
    List<GroupTaskArtifactPlanSlot> slots = const [],
    String notes = '',
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return null;
    try {
      final plan = GroupTaskArtifactPlan(
        orchestrationId: orchestrationId,
        storeTaskId: storeTaskId.trim(),
        slots: slots,
        notes: notes,
      );
      return await GroupWorkspaceService.instance.writeTaskArtifactPlan(
        groupId: groupId,
        plan: plan,
      );
    } catch (e, st) {
      LoggerService().error(
        'publish artifact plan failed: $groupId/$orchestrationId',
        tag: 'GroupArtifactRegistry',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  static Future<GroupTaskArtifactManifest?> registerEntries({
    required String groupId,
    required String orchestrationId,
    required List<GroupTaskArtifactEntry> entries,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks || entries.isEmpty) {
      return null;
    }
    try {
      return await GroupWorkspaceService.instance.registerTaskArtifacts(
        groupId: groupId,
        orchestrationId: orchestrationId,
        entries: entries,
      );
    } catch (e, st) {
      LoggerService().error(
        'register artifacts failed: $groupId/$orchestrationId',
        tag: 'GroupArtifactRegistry',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// 从 results.json 与 finish 轮次 URI 自动合并进 manifest。
  static Future<GroupTaskArtifactManifest?> syncFromTaskOutcomes({
    required String groupId,
    required String orchestrationId,
    GroupTaskResults? results,
    List<String> extraUris = const [],
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return null;
    try {
      final ws = GroupWorkspaceService.instance;
      final resolvedResults = results ??
          await ws.readTaskResults(
            groupId: groupId,
            orchestrationId: orchestrationId,
          );
      final entries = <GroupTaskArtifactEntry>[];

      if (resolvedResults != null) {
        for (final member in resolvedResults.members) {
          for (final uri in member.artifactUris) {
            entries.add(GroupTaskArtifactEntry(
              uri: uri,
              label: GroupTaskDisplay.artifactLabel(uri),
              producedBy: member.agentName,
              source: GroupTaskArtifactEntry.sourceMember,
            ));
          }
        }
      }

      for (final uri in extraUris) {
        final trimmed = uri.trim();
        if (trimmed.isEmpty) continue;
        entries.add(GroupTaskArtifactEntry(
          uri: trimmed,
          label: GroupTaskDisplay.artifactLabel(trimmed),
          source: GroupTaskArtifactEntry.sourceAuto,
        ));
      }

      if (entries.isEmpty) return null;
      return await ws.registerTaskArtifacts(
        groupId: groupId,
        orchestrationId: orchestrationId,
        entries: entries,
      );
    } catch (e) {
      LoggerService().debug(
        'sync artifacts failed: $groupId/$orchestrationId — $e',
        tag: 'GroupArtifactRegistry',
      );
      return null;
    }
  }

  static Future<String> loadAdminArtifactBlock({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return '';
    try {
      final ws = GroupWorkspaceService.instance;
      final parts = <String>[];

      final plan = await ws.readTaskArtifactPlan(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (plan != null) {
        parts.add(plan.toAdminBlock());
      }

      final manifest = await ws.readTaskArtifactManifest(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (manifest != null && manifest.entries.isNotEmpty) {
        final lines = <String>['【已登记产物（artifacts.json）】'];
        for (final entry in manifest.entries) {
          final label = entry.label.isNotEmpty ? entry.label : entry.uri;
          final by = entry.producedBy.isNotEmpty ? ' (${entry.producedBy})' : '';
          lines.add('- $label$by: ${entry.uri}');
        }
        parts.add(lines.join('\n'));
      }
      return parts.isEmpty ? '' : '\n\n${parts.join('\n\n')}';
    } catch (_) {
      return '';
    }
  }

  static Future<String> loadMemberArtifactPlanNote({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return '';
    try {
      final plan = await GroupWorkspaceService.instance.readTaskArtifactPlan(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (plan == null) return '';
      return '\n\n${plan.toAdminBlock()}\n'
          '写入产物时务必 `shepaw store write --task ${plan.storeTaskId} …`，'
          '并在回复中原样引用 store:// URI。';
    } catch (_) {
      return '';
    }
  }

  /// 从任意文本批量提取 store:// 并登记（admin 整理散落产物时用）。
  static List<GroupTaskArtifactEntry> entriesFromText(
    String text, {
    String source = GroupTaskArtifactEntry.sourceAdmin,
    String producedBy = '',
  }) {
    final uris = GroupMemberHistory.extractStoreUris(text);
    return [
      for (final uri in uris)
        GroupTaskArtifactEntry(
          uri: uri,
          label: GroupTaskDisplay.artifactLabel(uri),
          producedBy: producedBy,
          source: source,
        ),
    ];
  }
}
