import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/inference_log_entry.dart';
import '../models/trace_models.dart';
import 'trace_database_service.dart';

/// Persistent trace storage service backed by the independent `agent_traces.db`.
///
/// Supports concurrent traces — each active trace is keyed by its traceId.
/// Write operations accumulate in memory and are batch-committed on [endTrace].
/// Read operations always hit the database.
class TraceService extends ChangeNotifier {
  TraceService._();
  static final TraceService instance = TraceService._();

  final _db = TraceDatabaseService();
  final _uuid = const Uuid();

  // Retention limits
  static const int _maxTraces = 2000;
  static const int _maxAgeDays = 90;
  static const int _maxDbBytes = 500 * 1024 * 1024; // 500 MB

  // In-memory accumulators keyed by traceId — supports concurrent traces
  final Map<String, _ActiveTrace> _activeSessions = {};

  // Reverse index: spanId -> traceId, so endSpan can find the right session
  final Map<String, String> _spanToTraceId = {};

  // ---------------------------------------------------------------------------
  // Write API
  // ---------------------------------------------------------------------------

  /// Begin a new agent trace. Returns the trace id (same as [sessionId]).
  String beginTrace({
    required String sessionId,
    required String agentId,
    required String agentName,
    String? channelId,
    String? provider,
    String? model,
    String? executionMode,
    String? systemPrompt,
    required String userMessage,
    String? parentTraceId,
    String? traceRole,
  }) {
    final now = DateTime.now();
    final entry = TraceEntry(
      id: sessionId,
      channelId: channelId,
      agentId: agentId,
      agentName: agentName,
      provider: provider,
      model: model,
      executionMode: executionMode,
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      parentTraceId: parentTraceId,
      traceRole: traceRole,
      status: InferenceStatus.inProgress,
      startTime: now,
      createdAt: now,
    );

    _activeSessions[sessionId] = _ActiveTrace(entry: entry);
    return sessionId;
  }

  /// Begin a group orchestration root trace. Returns the orchestration trace id.
  String beginGroupOrchestration({
    required String channelId,
    required String adminAgentId,
    required String adminAgentName,
    required String userMessage,
    required List<String> memberAgentIds,
    bool planningMode = false,
    bool flowMode = false,
  }) {
    final sessionId = _uuid.v4();
    final now = DateTime.now();
    final mode = flowMode
        ? 'group_flow'
        : planningMode
            ? 'group_plan'
            : 'group_orchestration';
    final entry = TraceEntry(
      id: sessionId,
      channelId: channelId,
      agentId: adminAgentId,
      agentName: adminAgentName,
      executionMode: mode,
      userMessage: userMessage,
      parentTraceId: null,
      traceRole: 'group_orchestration',
      status: InferenceStatus.inProgress,
      startTime: now,
      createdAt: now,
      systemPrompt: json.encode({
        'member_agent_ids': memberAgentIds,
        'planning_mode': planningMode,
        'flow_mode': flowMode,
      }),
    );
    _activeSessions[sessionId] = _ActiveTrace(entry: entry);
    return sessionId;
  }

  /// End the active trace and batch-write everything to SQLite.
  Future<void> endTrace(
    String traceId,
    InferenceStatus status, {
    String? error,
    int totalTextChars = 0,
  }) async {
    final active = _activeSessions.remove(traceId);
    if (active == null) return;

    final now = DateTime.now();
    active.entry
      ..status = status
      ..endTime = now
      ..durationMs = now.difference(active.entry.startTime).inMilliseconds
      ..errorMessage = error
      ..totalRounds = active.spans
          .where((s) => s.spanType == 'llm_call')
          .length
      ..totalToolCalls = active.spans
          .where((s) => s.spanType == 'tool_call')
          .length
      ..totalTextChars = totalTextChars;

    // Batch write in a single transaction
    try {
      final db = await _db.database;
      await db.transaction((txn) async {
        await txn.insert(
          'traces',
          active.entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        for (final span in active.spans) {
          await txn.insert(
            'trace_spans',
            span.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      debugPrint('[TraceService] Failed to persist trace $traceId: $e');
    }

    notifyListeners();
  }

  /// Add a span to the specified trace. Returns the span id.
  String addSpan({
    required String traceId,
    String? parentSpanId,
    required String spanType,
    String? name,
    String? model,
    Map<String, dynamic>? inputData,
    Map<String, dynamic>? metadata,
  }) {
    final active = _activeSessions[traceId];
    if (active == null) return '';

    final id = _uuid.v4();
    final span = TraceSpan(
      id: id,
      traceId: traceId,
      parentSpanId: parentSpanId,
      spanType: spanType,
      name: name,
      model: model,
      sequenceNumber: active.spans.length,
      startTime: DateTime.now(),
      status: 'in_progress',
      inputData: inputData != null ? json.encode(inputData) : null,
      metadata: metadata != null ? json.encode(metadata) : null,
    );

    active.spans.add(span);
    active.spanIndex[id] = span;
    _spanToTraceId[id] = traceId;
    return id;
  }

  /// Complete a span with output data.
  void endSpan(
    String spanId, {
    Map<String, dynamic>? outputData,
    String status = 'completed',
    String? error,
  }) {
    if (spanId.isEmpty) return;

    final traceId = _spanToTraceId.remove(spanId);
    if (traceId == null) return;
    final active = _activeSessions[traceId];
    if (active == null) return;
    final span = active.spanIndex[spanId];
    if (span == null) return;

    final now = DateTime.now();
    span
      ..endTime = now
      ..durationMs = now.difference(span.startTime).inMilliseconds
      ..status = status
      ..errorMessage = error
      ..outputData = outputData != null ? json.encode(outputData) : null;
  }

  // ---------------------------------------------------------------------------
  // Query API
  // ---------------------------------------------------------------------------

  /// Query traces with optional filters. Returns newest first.
  Future<List<TraceEntry>> queryTraces({
    String? channelId,
    String? agentId,
    InferenceStatus? status,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final db = await _db.database;

      final conditions = <String>[];
      final args = <dynamic>[];

      if (channelId != null) {
        conditions.add('channel_id = ?');
        args.add(channelId);
      }
      if (agentId != null) {
        conditions.add('agent_id = ?');
        args.add(agentId);
      }
      if (status != null) {
        conditions.add('status = ?');
        args.add(status.name);
      }

      final where = conditions.isNotEmpty ? conditions.join(' AND ') : null;

      final rows = await db.query(
        'traces',
        where: where,
        whereArgs: args.isNotEmpty ? args : null,
        orderBy: 'start_time DESC',
        limit: limit,
        offset: offset,
      );

      return rows.map(TraceEntry.fromMap).toList();
    } catch (e) {
      debugPrint('[TraceService] queryTraces error: $e');
      return [];
    }
  }

  /// Load a single trace with all its spans.
  Future<TraceEntry?> getTraceDetail(String traceId) async {
    try {
      final db = await _db.database;

      final traceRows = await db.query(
        'traces',
        where: 'id = ?',
        whereArgs: [traceId],
        limit: 1,
      );
      if (traceRows.isEmpty) return null;

      final entry = TraceEntry.fromMap(traceRows.first);

      final spanRows = await db.query(
        'trace_spans',
        where: 'trace_id = ?',
        whereArgs: [traceId],
        orderBy: 'sequence_number ASC',
      );
      entry.spans = spanRows.map(TraceSpan.fromMap).toList();

      return entry;
    } catch (e) {
      debugPrint('[TraceService] getTraceDetail error: $e');
      return null;
    }
  }

  /// Load all child agent traces for a group orchestration trace.
  Future<List<TraceEntry>> getChildTraces(String parentTraceId) async {
    try {
      final db = await _db.database;
      final rows = await db.query(
        'traces',
        where: 'parent_trace_id = ?',
        whereArgs: [parentTraceId],
        orderBy: 'start_time ASC',
      );
      return rows.map(TraceEntry.fromMap).toList();
    } catch (e) {
      debugPrint('[TraceService] getChildTraces error: $e');
      return [];
    }
  }

  /// Aggregate stats across all traces.
  Future<Map<String, dynamic>> getStats() async {
    try {
      final db = await _db.database;

      final total = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM traces')) ??
          0;
      final completed = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM traces WHERE status = 'completed'")) ??
          0;
      final errors = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM traces WHERE status = 'error'")) ??
          0;
      final inProgress = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM traces WHERE status = 'in_progress'")) ??
          0;

      return {
        'total': total,
        'completed': completed,
        'errors': errors,
        'inProgress': inProgress,
      };
    } catch (e) {
      debugPrint('[TraceService] getStats error: $e');
      return {'total': 0, 'completed': 0, 'errors': 0, 'inProgress': 0};
    }
  }

  // ---------------------------------------------------------------------------
  // Management
  // ---------------------------------------------------------------------------

  /// Apply retention policy: max 2000 traces, 90 days, 500 MB.
  Future<void> cleanup() async {
    try {
      final db = await _db.database;

      // Age-based cleanup
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _maxAgeDays))
          .toIso8601String();
      await db.delete(
        'traces',
        where: 'start_time < ?',
        whereArgs: [cutoff],
      );

      // Count-based cleanup: keep newest _maxTraces
      final count = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM traces')) ??
          0;
      if (count > _maxTraces) {
        final excess = count - _maxTraces;
        await db.rawDelete('''
          DELETE FROM traces WHERE id IN (
            SELECT id FROM traces ORDER BY start_time ASC LIMIT ?
          )
        ''', [excess]);
      }

      // Size-based cleanup
      final sizeResult = await db
          .rawQuery('SELECT page_count * page_size AS size FROM pragma_page_count(), pragma_page_size()');
      if (sizeResult.isNotEmpty) {
        final size = sizeResult.first['size'] as int? ?? 0;
        if (size > _maxDbBytes) {
          // Remove oldest 20% when over limit
          final toDelete = (count * 0.2).ceil();
          await db.rawDelete('''
            DELETE FROM traces WHERE id IN (
              SELECT id FROM traces ORDER BY start_time ASC LIMIT ?
            )
          ''', [toDelete]);
        }
      }

      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      debugPrint('[TraceService] cleanup error: $e');
    }
  }

  /// Export all traces as JSONL (one JSON object per line).
  Future<String> exportAsJsonl() async {
    try {
      final db = await _db.database;
      final traceRows = await db.query('traces', orderBy: 'start_time DESC');
      final buffer = StringBuffer();

      for (final row in traceRows) {
        final entry = TraceEntry.fromMap(row);
        final spanRows = await db.query(
          'trace_spans',
          where: 'trace_id = ?',
          whereArgs: [entry.id],
          orderBy: 'sequence_number ASC',
        );
        entry.spans = spanRows.map(TraceSpan.fromMap).toList();
        buffer.writeln(json.encode(entry.toJson()));
      }

      return buffer.toString();
    } catch (e) {
      debugPrint('[TraceService] exportAsJsonl error: $e');
      return '';
    }
  }

  /// Delete a single trace and its spans.
  Future<void> deleteTrace(String traceId) async {
    try {
      final db = await _db.database;
      await db.delete('traces', where: 'id = ?', whereArgs: [traceId]);
      notifyListeners();
    } catch (e) {
      debugPrint('[TraceService] deleteTrace error: $e');
    }
  }

  /// Clear all traces and spans.
  Future<void> clearAll() async {
    try {
      final db = await _db.database;
      await db.delete('trace_spans');
      await db.delete('traces');
      notifyListeners();
    } catch (e) {
      debugPrint('[TraceService] clearAll error: $e');
    }
  }

  /// Delete all traces (and their spans via CASCADE) for [channelId].
  Future<void> clearByChannel(String channelId) async {
    try {
      final db = await _db.database;
      await db.delete('traces', where: 'channel_id = ?', whereArgs: [channelId]);
      notifyListeners();
    } catch (e) {
      debugPrint('[TraceService] clearByChannel error: $e');
    }
  }

  /// Get the size of the trace database file in bytes, or null if unavailable.
  Future<int?> getDatabaseSizeBytes() async {
    if (kIsWeb) return null;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, 'agent_traces.db');
      final file = File(path);
      if (await file.exists()) return await file.length();
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Internal accumulator for spans during an active trace session.
class _ActiveTrace {
  final TraceEntry entry;
  final List<TraceSpan> spans = [];
  final Map<String, TraceSpan> spanIndex = {};

  _ActiveTrace({required this.entry});
}
