import 'dart:async';

import '../models/dispatch_task.dart';
import '../models/remote_agent.dart';
import '../models/she_agent_impression.dart';
import 'agent_memory_store_service.dart';
import 'agent_soul_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';
import 'she_memory_db_service.dart';
import 'she_service.dart';

/// She 侧 Agent 印象索引：变更驱动刷新，供 roster prompt 注入。
class SheAgentImpressionService {
  SheAgentImpressionService._();
  static final SheAgentImpressionService instance =
      SheAgentImpressionService._();

  static const _tag = 'SheAgentImpression';
  static const _indexKey = 'agent_impressions_index';
  static const _announcementsKey = 'agent_impression_announcements';
  static const _maxSheObservations = 5;

  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _sheMemory = SheMemoryDbService.instance;

  /// 后台刷新单个 agent（不阻塞调用方）。
  void scheduleRefresh(String agentId, {bool announce = true}) {
    if (agentId.isEmpty || SheService.isSheIdentity(agentId)) return;
    unawaited(refreshImpression(agentId, announce: announce).catchError((Object e) {
      _log.warning('refresh impression failed for $agentId: $e', tag: _tag);
      return null;
    }));
  }

  /// 批量后台刷新。
  void scheduleRefreshAll(Iterable<String> agentIds, {bool announce = true}) {
    for (final id in agentIds) {
      scheduleRefresh(id, announce: announce);
    }
  }

  /// 派发终态后沉淀 She 侧观察（比全量 refresh 更轻）。
  void scheduleRecordDispatchOutcome(
    String agentId,
    String status, {
    String? errorMessage,
  }) {
    if (agentId.isEmpty || SheService.isSheIdentity(agentId)) return;
    unawaited(recordDispatchOutcome(
      agentId,
      status,
      errorMessage: errorMessage,
    ).catchError((Object e) {
      _log.warning('record dispatch outcome failed for $agentId: $e', tag: _tag);
    }));
  }

  /// She 通过 `agents.memory-write --keywords dispatch` 写入的观察同步到此。
  Future<void> appendSheObservation(String agentId, String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || SheService.isSheIdentity(agentId)) return;

    var index = await _loadIndex();
    var imp = index[agentId];
    if (imp == null) {
      await refreshImpression(agentId, announce: false);
      index = await _loadIndex();
      imp = index[agentId];
      if (imp == null) return;
    }

    final obs = _prependObservation(imp.sheObservations, trimmed);
    index[agentId] = imp.copyWith(
      sheObservations: obs,
      experienceHint: buildExperienceHint(
        stats: imp.dispatchStats,
        sheObservations: obs,
      ),
      lastVerifiedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveIndex(index);
  }

  Future<void> recordDispatchOutcome(
    String agentId,
    String status, {
    String? errorMessage,
  }) async {
    if (agentId.isEmpty || SheService.isSheIdentity(agentId)) return;

    final observation =
        buildDispatchObservation(status, errorMessage: errorMessage);
    var index = await _loadIndex();
    var imp = index[agentId];
    if (imp == null) {
      await refreshImpression(agentId, announce: false);
      index = await _loadIndex();
      imp = index[agentId];
      if (imp == null) return;
    }

    Map<String, int> stats = imp.dispatchStats;
    try {
      stats = await _db.getDispatchStatsForAgent(agentId);
    } catch (e) {
      _log.warning('read dispatch stats for $agentId: $e', tag: _tag);
    }

    final obs = _prependObservation(imp.sheObservations, observation);
    index[agentId] = imp.copyWith(
      sheObservations: obs,
      dispatchStats: stats,
      experienceHint: buildExperienceHint(
        stats: stats,
        sheObservations: obs,
      ),
      lastVerifiedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveIndex(index);
  }

  /// 构建并消费待通知队列（She 1:1 每轮至多注入一次）。
  Future<String> buildAndConsumeAnnouncementsBlock() async {
    final queue = await _loadAnnouncements();
    if (queue.isEmpty) return '';
    final block = formatAnnouncementsBlock(queue);
    await _saveAnnouncements(const []);
    return block;
  }

  Future<void> removeImpression(String agentId) async {
    if (agentId.isEmpty) return;
    final index = await _loadIndex();
    if (!index.containsKey(agentId)) return;
    index.remove(agentId);
    await _saveIndex(index);
    await _removeAnnouncementsFor(agentId);
  }

  Future<Map<String, SheAgentImpression>> getAllImpressions() =>
      _loadIndex();

  Future<SheAgentImpression?> getImpression(String agentId) async {
    final index = await _loadIndex();
    return index[agentId];
  }

  /// 重建单个 agent 的印象（与 [AgentProfileService] summary 同源逻辑）。
  Future<SheAgentImpression?> refreshImpression(
    String agentId, {
    bool announce = true,
  }) async {
    if (agentId.isEmpty || SheService.isSheIdentity(agentId)) return null;
    final agent = await _db.getRemoteAgentById(agentId);
    if (agent == null) {
      await removeImpression(agentId);
      return null;
    }
    if (agent.hiddenOnThisApp) {
      await removeImpression(agentId);
      return null;
    }
    return refreshImpressionForAgent(agent, announce: announce);
  }

  Future<SheAgentImpression?> refreshImpressionForAgent(
    RemoteAgent agent, {
    bool announce = true,
  }) async {
    if (SheService.isSheIdentity(agent.id, agent.metadata) ||
        agent.hiddenOnThisApp) {
      return null;
    }

    var soul = '';
    try {
      soul = (await AgentSoulService.instance.getSoul(agent)).trim();
    } catch (e) {
      _log.warning('read soul for impression ${agent.id}: $e', tag: _tag);
    }

    Map<String, int> stats = const {};
    List<String> learnings = const [];
    try {
      stats = await _db.getDispatchStatsForAgent(agent.id);
    } catch (e) {
      _log.warning('read dispatch stats for ${agent.id}: $e', tag: _tag);
    }
    try {
      final mems = await AgentMemoryStoreService.forAgent(agent.id)
          .queryByKeyword('dispatch', limit: 3);
      learnings = mems
          .map((m) => m.memoryContent.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (e) {
      _log.warning('read dispatch learnings for ${agent.id}: $e', tag: _tag);
    }

    final index = await _loadIndex();
    final previous = index[agent.id];
    final oneLineRole = buildOneLineRole(agent, soul);
    final sheObservations = _mergeObservations(
      previous?.sheObservations ?? const [],
      learnings,
    );

    if (announce) {
      if (previous == null) {
        await _enqueueAnnouncement(
          SheAgentImpressionAnnouncement(
            agentId: agent.id,
            agentName: agent.name,
            oneLineRole: oneLineRole,
            kind: 'new',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else if (previous.agentName != agent.name ||
          previous.oneLineRole != oneLineRole) {
        await _enqueueAnnouncement(
          SheAgentImpressionAnnouncement(
            agentId: agent.id,
            agentName: agent.name,
            oneLineRole: oneLineRole,
            kind: 'updated',
            previousOneLineRole: previous.oneLineRole,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    }

    final impression = SheAgentImpression(
      agentId: agent.id,
      agentName: agent.name,
      oneLineRole: oneLineRole,
      experienceHint: buildExperienceHint(
        stats: stats,
        learnings: learnings,
        sheObservations: sheObservations,
      ),
      lastVerifiedAt: DateTime.now().millisecondsSinceEpoch,
      dispatchStats: stats,
      sheObservations: sheObservations,
    );

    index[agent.id] = impression;
    await _saveIndex(index);
    return impression;
  }

  /// 启动 / She 初始化时：为缺失或落后于 agent.updatedAt 的条目补刷。
  Future<void> refreshStaleImpressions() async {
    List<RemoteAgent> agents;
    try {
      agents = (await _db.getAllRemoteAgents())
          .where((a) =>
              !SheService.isSheIdentity(a.id, a.metadata) &&
              !a.hiddenOnThisApp)
          .toList();
    } catch (e) {
      _log.warning('refreshStaleImpressions list failed: $e', tag: _tag);
      return;
    }

    final index = await _loadIndex();
    for (final agent in agents) {
      final existing = index[agent.id];
      final stale = existing == null ||
          existing.lastVerifiedAt < agent.updatedAt ||
          existing.agentName != agent.name;
      if (stale) {
        await refreshImpressionForAgent(agent, announce: false);
      }
    }

    final refreshedIndex = await _loadIndex();
    final liveIds = agents.map((a) => a.id).toSet();
    final staleIds =
        refreshedIndex.keys.where((id) => !liveIds.contains(id)).toList();
    if (staleIds.isEmpty) return;
    for (final id in staleIds) {
      refreshedIndex.remove(id);
    }
    await _saveIndex(refreshedIndex);
  }

  /// 权威摘要：soul 首条实质行 → bio → capabilities → skills 后缀。
  static String buildOneLineRole(RemoteAgent agent, String soul) {
    var role = _firstSubstantiveLine(soul);
    if (role.isEmpty) {
      role = (agent.bio ?? '').trim();
    }
    if (role.isEmpty && agent.capabilities.isNotEmpty) {
      role = agent.capabilities.take(3).join(', ');
    }
    if (role.isEmpty) {
      role = 'No specialty configured yet';
    }

    final skills = agent.enabledSkills.take(3).toList();
    if (skills.isNotEmpty) {
      final suffix = '; skills: ${skills.join(', ')}';
      if (role.length + suffix.length <= 120) {
        role = '$role$suffix';
      }
    }

    return _truncate(role, 120);
  }

  /// 经验摘要：She 观察 → agent memory learning → 战绩统计。
  static String? buildExperienceHint({
    Map<String, int>? stats,
    List<String>? learnings,
    List<String>? sheObservations,
  }) {
    if (sheObservations != null && sheObservations.isNotEmpty) {
      return _truncate(sheObservations.first.trim(), 80);
    }
    if (learnings != null && learnings.isNotEmpty) {
      return _truncate(learnings.first.trim(), 80);
    }
    final done = stats?['done'] ?? 0;
    final error = stats?['error'] ?? 0;
    final timeout = stats?['timeout'] ?? 0;
    final total = done + error + timeout;
    if (total == 0) {
      return 'Not yet verified by dispatch';
    }
    return 'Dispatch record: $done ok, $error fail, $timeout timeout';
  }

  static String buildDispatchObservation(
    String status, {
    String? errorMessage,
  }) {
    final date = DateTime.now().toIso8601String().substring(0, 10);
    if (status == DispatchTask.statusDone) {
      return 'Dispatch succeeded ($date)';
    }
    if (status == DispatchTask.statusTimeout) {
      return 'Dispatch timed out ($date)';
    }
    final err = _truncate((errorMessage ?? 'failed').trim(), 60);
    return 'Dispatch failed ($date): $err';
  }

  static String formatAnnouncementsBlock(
    List<SheAgentImpressionAnnouncement> items,
  ) {
    if (items.isEmpty) return '';
    final buf = StringBuffer(
      '## Agent Directory Updates (mention once if natural)\n\n',
    );
    for (final item in items) {
      if (item.isNew) {
        buf.writeln(
          '- **NEW** ${item.agentName} (`${item.agentId}`): '
          '${item.oneLineRole}',
        );
      } else {
        buf.writeln(
          '- **UPDATED** ${item.agentName} (`${item.agentId}`): '
          'now "${item.oneLineRole}"'
          '${item.previousOneLineRole != null && item.previousOneLineRole!.isNotEmpty ? ' (was "${item.previousOneLineRole}")' : ''}',
        );
      }
    }
    buf.write(
      '\nBriefly tell your master about new/updated agents when it fits the '
      'conversation — one sentence each, no directory dump.',
    );
    return buf.toString();
  }

  /// 供 CLI / 调试渲染的目录行（不注入 She 系统提示词）。
  static List<String> formatDirectoryLines({
    required List<RemoteAgent> agents,
    required Map<String, SheAgentImpression> impressions,
    int maxAgents = 20,
  }) {
    final lines = <String>[];
    final shown = agents.take(maxAgents).toList();
    for (final agent in shown) {
      final imp = impressions[agent.id];
      final status = agent.isOnline ? 'online' : 'offline';
      final role = (imp?.oneLineRole ?? (agent.bio ?? '')).trim();
      final exp = imp?.experienceHint?.trim();
      final buf = StringBuffer('- **${agent.name}** ($status): ');
      if (role.isNotEmpty) {
        buf.write(role);
      }
      if (exp != null && exp.isNotEmpty) {
        if (role.isNotEmpty) buf.write('; ');
        buf.write(exp);
      }
      if (role.isEmpty && (exp == null || exp.isEmpty)) {
        buf.write('profile pending refresh');
      }
      lines.add(buf.toString());
    }
    if (agents.length > maxAgents) {
      lines.add(
        '- …+${agents.length - maxAgents} more (see `shepaw context agents.list`)',
      );
    }
    return lines;
  }

  static List<String> _mergeObservations(
    List<String> existing,
    List<String> learnings,
  ) {
    final out = <String>[...existing];
    for (final learning in learnings) {
      final trimmed = learning.trim();
      if (trimmed.isEmpty) continue;
      if (out.any((o) => o.trim() == trimmed)) continue;
      out.insert(0, trimmed);
    }
    return out.take(_maxSheObservations).toList();
  }

  static List<String> _prependObservation(
    List<String> existing,
    String observation,
  ) {
    final trimmed = observation.trim();
    if (trimmed.isEmpty) return existing;
    final out = [trimmed, ...existing.where((o) => o.trim() != trimmed)];
    return out.take(_maxSheObservations).toList();
  }

  static String _firstNonEmptyLine(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  /// 跳过空行、Markdown 标题、以及 lone section 标签（如 "Specialty"）。
  static String _firstSubstantiveLine(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      var trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      trimmed = trimmed.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (trimmed.isEmpty) continue;
      if (RegExp(
        r'^(specialty|专长|identity|角色|about|简介|soul|persona)$',
        caseSensitive: false,
      ).hasMatch(trimmed)) {
        continue;
      }
      return trimmed;
    }
    return '';
  }

  static String _truncate(String text, int max) {
    if (text.length <= max) return text;
    if (max <= 1) return text.substring(0, max);
    return '${text.substring(0, max - 1)}…';
  }

  Future<void> _enqueueAnnouncement(
    SheAgentImpressionAnnouncement item,
  ) async {
    final queue = await _loadAnnouncements();
    queue.removeWhere((a) => a.agentId == item.agentId && a.kind == item.kind);
    queue.add(item);
    await _saveAnnouncements(queue);
  }

  Future<void> _removeAnnouncementsFor(String agentId) async {
    final queue = await _loadAnnouncements();
    final filtered = queue.where((a) => a.agentId != agentId).toList();
    if (filtered.length == queue.length) return;
    await _saveAnnouncements(filtered);
  }

  Future<List<SheAgentImpressionAnnouncement>> _loadAnnouncements() async {
    final raw = await _sheMemory.getSheMemory(_announcementsKey);
    return SheAgentImpressionAnnouncement.decodeList(raw);
  }

  Future<void> _saveAnnouncements(
    List<SheAgentImpressionAnnouncement> items,
  ) async {
    await _sheMemory.setSheMemory(
      _announcementsKey,
      SheAgentImpressionAnnouncement.encodeList(items),
    );
  }

  Future<Map<String, SheAgentImpression>> _loadIndex() async {
    final raw = await _sheMemory.getSheMemory(_indexKey);
    return SheAgentImpression.decodeIndex(raw);
  }

  Future<void> _saveIndex(Map<String, SheAgentImpression> index) async {
    await _sheMemory.setSheMemory(_indexKey, SheAgentImpression.encodeIndex(index));
  }
}
