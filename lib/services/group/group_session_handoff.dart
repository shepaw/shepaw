import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Session-level handoff package when a group admin opens a new session.
///
/// Distinct from store `handoff.create` (artifact A→B ack). See
/// `.ai_workspace/GROUP_SESSION_HANDOFF_SCHEMA.md`.
class GroupSessionHandoff {
  GroupSessionHandoff({
    required this.handoffId,
    required this.reasonCode,
    required this.userGoal,
    required this.acceptanceCriteria,
    required this.status,
    this.reasonDetail,
    this.title,
    this.statusNote,
    this.sourceSessionId,
    this.sourceSessionLabel,
    this.orchestrationId,
    this.orchestrationSummary,
    this.constraints = const [],
    this.artifacts = const [],
    this.openItems = const [],
    this.roles = const [],
    this.firstMessageDraft,
    this.createdByAgentId,
    this.createdByAgentName,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  static const schemaVersion = 1;
  static const metaActionKey = 'group_session_action';

  static const validReasonCodes = {
    'topic_shift',
    'post_delivery',
    'noise_reduction',
    'agent_memory_reset',
    'parallel_track',
    'user_requested',
  };

  static const validStatuses = {
    'not_started',
    'in_progress',
    'delivered',
    'blocked',
  };

  final String handoffId;
  final String reasonCode;
  final String? reasonDetail;
  final String userGoal;
  final List<String> acceptanceCriteria;
  final String status;
  final String? title;
  final String? statusNote;
  final String? sourceSessionId;
  final String? sourceSessionLabel;
  final String? orchestrationId;
  final String? orchestrationSummary;
  final List<String> constraints;
  final List<GroupSessionHandoffArtifact> artifacts;
  final List<Map<String, dynamic>> openItems;
  final List<Map<String, dynamic>> roles;
  final String? firstMessageDraft;
  final String? createdByAgentId;
  final String? createdByAgentName;
  final DateTime createdAt;

  String get displayTitle =>
      title?.trim().isNotEmpty == true ? title!.trim() : userGoal.trim();

  static String shortSessionId(String sessionId) {
    final trimmed = sessionId.trim();
    if (trimmed.length <= 8) return trimmed;
    return trimmed.substring(trimmed.length - 8);
  }

  static String generateHandoffId() {
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '');
    final tail = const Uuid().v4().substring(0, 8);
    return 'ho_${ts}_$tail';
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'handoff_id': handoffId,
        'created_at': createdAt.toIso8601String(),
        if (createdByAgentId != null)
          'created_by': {
            'agent_id': createdByAgentId,
            if (createdByAgentName != null) 'agent_name': createdByAgentName,
            'role': 'group_admin',
          },
        if (sourceSessionId != null || orchestrationId != null)
          'source': {
            if (sourceSessionId != null) 'session_id': sourceSessionId,
            if (sourceSessionLabel != null)
              'session_label': sourceSessionLabel,
            if (orchestrationId != null) 'orchestration_id': orchestrationId,
            if (orchestrationSummary != null)
              'orchestration_summary': orchestrationSummary,
          },
        'reason': {
          'code': reasonCode,
          if (reasonDetail != null && reasonDetail!.trim().isNotEmpty)
            'detail': reasonDetail!.trim(),
        },
        'task': {
          if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
          'user_goal': userGoal.trim(),
          'acceptance_criteria': acceptanceCriteria,
          'status': status,
          if (statusNote != null && statusNote!.trim().isNotEmpty)
            'status_note': statusNote!.trim(),
        },
        if (constraints.isNotEmpty) 'constraints': constraints,
        if (artifacts.isNotEmpty)
          'artifacts': [for (final a in artifacts) a.toJson()],
        if (openItems.isNotEmpty) 'open_items': openItems,
        if (roles.isNotEmpty) 'roles': roles,
        'inherit': {
          'group_memory': true,
          'workspace_artifacts': true,
          'chat_history': false,
          'loop_events': false,
          'member_dm_context': false,
        },
        if (firstMessageDraft != null && firstMessageDraft!.trim().isNotEmpty)
          'first_message_draft': firstMessageDraft!.trim(),
      };

  String toMarkdown({required String jsonUri}) {
    final buf = StringBuffer()
      ..writeln('# 会话交接 · ${displayTitle}')
      ..writeln()
      ..writeln('- **交接 ID**: $handoffId');
    if (sourceSessionId != null) {
      buf.writeln(
        '- **来源会话**: $sourceSessionId'
        '${orchestrationSummary != null ? '（$orchestrationSummary）' : ''}',
      );
    }
    if (reasonDetail != null && reasonDetail!.trim().isNotEmpty) {
      buf.writeln('- **原因**: ${reasonDetail!.trim()}');
    } else {
      buf.writeln('- **原因**: $reasonCode');
    }
    buf
      ..writeln('- **状态**: $status')
      ..writeln()
      ..writeln('## 用户目标')
      ..writeln()
      ..writeln(userGoal.trim())
      ..writeln()
      ..writeln('## 验收标准')
      ..writeln();
    for (final c in acceptanceCriteria) {
      buf.writeln('- [ ] ${c.trim()}');
    }
    if (constraints.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 关键决策（不可推翻）')
        ..writeln();
      for (final c in constraints) {
        buf.writeln('- ${c.trim()}');
      }
    }
    if (artifacts.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 相关产物')
        ..writeln();
      for (final a in artifacts) {
        final label = a.label?.trim().isNotEmpty == true ? a.label! : a.uri;
        buf.writeln('- [$label](${a.uri})');
      }
    }
    if (openItems.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 开放问题 / 待办')
        ..writeln();
      for (final item in openItems) {
        final summary = item['summary']?.toString().trim();
        if (summary != null && summary.isNotEmpty) {
          buf.writeln('- $summary');
        }
      }
    }
    if (roles.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 建议分工')
        ..writeln()
        ..writeln('| 成员 | 职责 |')
        ..writeln('|------|------|');
      for (final role in roles) {
        final name = role['agent_name']?.toString() ?? '';
        final r = role['role']?.toString() ?? '';
        if (name.isNotEmpty) buf.writeln('| $name | $r |');
      }
    }
    buf
      ..writeln()
      ..writeln('---')
      ..writeln('完整机器可读版本：`$jsonUri`');
    return buf.toString();
  }

  String formatFirstMessage({required String handoffUri}) {
    if (firstMessageDraft != null && firstMessageDraft!.trim().isNotEmpty) {
      return firstMessageDraft!.trim();
    }
    final sourceShort = sourceSessionId != null
        ? shortSessionId(sourceSessionId!)
        : 'unknown';
    final buf = StringBuffer()
      ..writeln('【任务继续 · 自会话 $sourceShort 交接】')
      ..writeln()
      ..writeln(userGoal.trim())
      ..writeln()
      ..writeln('验收标准：');
    for (var i = 0; i < acceptanceCriteria.length; i++) {
      buf.writeln('${i + 1}. ${acceptanceCriteria[i].trim()}');
    }
    buf
      ..writeln()
      ..writeln('关键上下文：$handoffUri')
      ..writeln()
      ..writeln(
        '请按 handoff 中的分工与产物 URI 继续；中间产出写入 store 并在回复中引用 URI。',
      );
    return buf.toString().trim();
  }

  static GroupSessionHandoff? fromJson(Map<String, dynamic> json) {
    final task = json['task'];
    if (task is! Map) return null;
    final userGoal = task['user_goal']?.toString().trim() ?? '';
    if (userGoal.isEmpty) return null;

    final rawCriteria = task['acceptance_criteria'];
    final criteria = <String>[];
    if (rawCriteria is List) {
      for (final c in rawCriteria) {
        final s = c.toString().trim();
        if (s.isNotEmpty) criteria.add(s);
      }
    }
    if (criteria.isEmpty) return null;

    final status = task['status']?.toString().trim() ?? '';
    if (!validStatuses.contains(status)) return null;

    final reason = json['reason'];
    final reasonCode = reason is Map
        ? reason['code']?.toString().trim() ?? ''
        : json['reason']?.toString().trim() ?? '';
    if (!validReasonCodes.contains(reasonCode)) return null;

    final source = json['source'];
    final createdBy = json['created_by'];

    final rawArtifacts = json['artifacts'];
    final artifacts = <GroupSessionHandoffArtifact>[];
    if (rawArtifacts is List) {
      for (final a in rawArtifacts) {
        if (a is Map) {
          final parsed = GroupSessionHandoffArtifact.fromJson(
            Map<String, dynamic>.from(a),
          );
          if (parsed != null) artifacts.add(parsed);
        }
      }
    }

    DateTime? createdAt;
    final rawCreated = json['created_at']?.toString();
    if (rawCreated != null && rawCreated.isNotEmpty) {
      createdAt = DateTime.tryParse(rawCreated);
    }

    return GroupSessionHandoff(
      handoffId: json['handoff_id']?.toString().trim().isNotEmpty == true
          ? json['handoff_id'].toString().trim()
          : generateHandoffId(),
      reasonCode: reasonCode,
      reasonDetail: reason is Map ? reason['detail']?.toString() : null,
      userGoal: userGoal,
      acceptanceCriteria: criteria,
      status: status,
      title: task['title']?.toString(),
      statusNote: task['status_note']?.toString(),
      sourceSessionId:
          source is Map ? source['session_id']?.toString() : null,
      sourceSessionLabel:
          source is Map ? source['session_label']?.toString() : null,
      orchestrationId:
          source is Map ? source['orchestration_id']?.toString() : null,
      orchestrationSummary:
          source is Map ? source['orchestration_summary']?.toString() : null,
      constraints: _stringList(json['constraints']),
      artifacts: artifacts,
      openItems: _mapList(json['open_items']),
      roles: _mapList(json['roles']),
      firstMessageDraft: json['first_message_draft']?.toString(),
      createdByAgentId:
          createdBy is Map ? createdBy['agent_id']?.toString() : null,
      createdByAgentName:
          createdBy is Map ? createdBy['agent_name']?.toString() : null,
      createdAt: createdAt,
    );
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
  }

  static List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// Parse inline `handoff` object or load from [handoffUri] JSON text.
  static ({GroupSessionHandoff? handoff, String? error}) parse({
    Map<String, dynamic>? inlineHandoff,
    String? handoffUri,
    String? handoffJsonText,
    String? sourceSessionId,
    String? createdByAgentId,
    String? createdByAgentName,
  }) {
    Map<String, dynamic>? raw;
    if (inlineHandoff != null && inlineHandoff.isNotEmpty) {
      raw = Map<String, dynamic>.from(inlineHandoff);
    } else if (handoffJsonText != null && handoffJsonText.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(handoffJsonText);
        if (decoded is Map) {
          raw = Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        return (handoff: null, error: 'handoff JSON parse failed: $e');
      }
    } else if (handoffUri != null && handoffUri.trim().isNotEmpty) {
      return (
        handoff: null,
        error: 'handoff_uri must be resolved before parse (got $handoffUri)',
      );
    } else {
      return (handoff: null, error: 'handoff or handoff_uri is required');
    }

    raw ??= {};
    final source = raw['source'];
    if (source is! Map && sourceSessionId != null) {
      raw['source'] = {
        'session_id': sourceSessionId,
        ...(source is Map ? Map<String, dynamic>.from(source) : {}),
      };
    } else if (source is Map &&
        sourceSessionId != null &&
        source['session_id'] == null) {
      raw['source'] = {
        ...Map<String, dynamic>.from(source),
        'session_id': sourceSessionId,
      };
    }

    if (raw['handoff_id'] == null) {
      raw['handoff_id'] = generateHandoffId();
    }

    final handoff = fromJson(raw);
    if (handoff == null) {
      return (
        handoff: null,
        error:
            'invalid handoff: task.user_goal, task.acceptance_criteria[], '
            'task.status, and reason.code are required',
      );
    }

    return (
      handoff: GroupSessionHandoff(
        handoffId: handoff.handoffId,
        reasonCode: handoff.reasonCode,
        reasonDetail: handoff.reasonDetail,
        userGoal: handoff.userGoal,
        acceptanceCriteria: handoff.acceptanceCriteria,
        status: handoff.status,
        title: handoff.title,
        statusNote: handoff.statusNote,
        sourceSessionId: handoff.sourceSessionId ?? sourceSessionId,
        sourceSessionLabel: handoff.sourceSessionLabel,
        orchestrationId: handoff.orchestrationId,
        orchestrationSummary: handoff.orchestrationSummary,
        constraints: handoff.constraints,
        artifacts: handoff.artifacts,
        openItems: handoff.openItems,
        roles: handoff.roles,
        firstMessageDraft: handoff.firstMessageDraft,
        createdByAgentId: createdByAgentId ?? handoff.createdByAgentId,
        createdByAgentName: createdByAgentName ?? handoff.createdByAgentName,
        createdAt: handoff.createdAt,
      ),
      error: null,
    );
  }
}

class GroupSessionHandoffArtifact {
  const GroupSessionHandoffArtifact({
    required this.uri,
    this.label,
    this.requiredRead = false,
  });

  final String uri;
  final String? label;
  final bool requiredRead;

  Map<String, dynamic> toJson() => {
        'uri': uri,
        if (label != null && label!.trim().isNotEmpty) 'label': label!.trim(),
        if (requiredRead) 'required_read': true,
      };

  static GroupSessionHandoffArtifact? fromJson(Map<String, dynamic> json) {
    final uri = json['uri']?.toString().trim() ?? '';
    if (uri.isEmpty) return null;
    return GroupSessionHandoffArtifact(
      uri: uri,
      label: json['label']?.toString(),
      requiredRead: json['required_read'] == true,
    );
  }
}
