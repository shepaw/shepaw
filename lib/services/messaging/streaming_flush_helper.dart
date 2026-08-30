import 'dart:async';

import '../../models/remote_agent.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../task/task_models.dart';

/// Default streaming flush interval (overridable via agent metadata).
const int kDefaultFlushIntervalMs = 2000;

/// Default content-length threshold before an early flush.
const int kDefaultContentThreshold = 500;

/// Periodic SQLite flush of in-flight streaming assistant content.
///
/// Used by ACP, Peer, and local LLM paths so a mid-stream cancel/crash still
/// leaves recoverable partial text in the channel.
class StreamingFlushHelper {
  StreamingFlushHelper({
    required LocalDatabaseService db,
    required this.activeTask,
    required this.agent,
    required this.channelId,
    required this.replyToId,
    required this.traceId,
    this.flushInterval = const Duration(milliseconds: kDefaultFlushIntervalMs),
    this.contentThreshold = kDefaultContentThreshold,
    this.enabled = true,
    this.onFlushed,
  }) : _db = db;

  factory StreamingFlushHelper.fromAgent({
    required LocalDatabaseService db,
    required ActiveTask activeTask,
    required RemoteAgent agent,
    required String channelId,
    required String replyToId,
    required String traceId,
    void Function(String messageId)? onFlushed,
  }) {
    final flushInterval = Duration(
      milliseconds:
          (agent.metadata['streaming_flush_interval_ms'] as num?)?.toInt() ??
              kDefaultFlushIntervalMs,
    );
    final contentThreshold =
        (agent.metadata['streaming_content_threshold'] as num?)?.toInt() ??
            kDefaultContentThreshold;
    final enabled = agent.metadata['streaming_enable_flushing'] != false;
    return StreamingFlushHelper(
      db: db,
      activeTask: activeTask,
      agent: agent,
      channelId: channelId,
      replyToId: replyToId,
      traceId: traceId,
      flushInterval: flushInterval,
      contentThreshold: contentThreshold,
      enabled: enabled && channelId.isNotEmpty,
      onFlushed: onFlushed,
    );
  }

  final LocalDatabaseService _db;
  final ActiveTask activeTask;
  final RemoteAgent agent;
  final String channelId;
  final String replyToId;
  final String traceId;
  final Duration flushInterval;
  final int contentThreshold;
  final bool enabled;

  /// Fired after a partial row was successfully written, with its message id.
  /// Peer turns use this to persist the id into the inflight-turn record so a
  /// process-kill restore can delete/reuse that exact row.
  final void Function(String messageId)? onFlushed;

  Timer? _timer;
  bool _scheduled = false;

  /// Start the periodic timer on first streaming chunk (idempotent).
  void schedule() {
    if (_scheduled || !enabled) return;
    _scheduled = true;

    _timer = Timer.periodic(flushInterval, (_) async {
      if (activeTask.isComplete) {
        cancel();
        return;
      }
      if (activeTask.shouldFlush(
        flushIntervalMs: flushInterval.inMilliseconds,
        contentThreshold: contentThreshold,
      )) {
        await flush();
      }
    });

    LoggerService().debug(
      'Scheduled streaming flush timer: ${flushInterval.inMilliseconds}ms, '
      '$contentThreshold char threshold (task $traceId)',
      tag: 'StreamingFlushHelper',
    );
  }

  Future<void> flush({Map<String, dynamic>? extraMetadata}) async {
    // 纯 thinking 阶段（answer 为空）也要落库：partial 行只要带上
    // `status:'streaming'` + `progress_content`，DB 里就有了「本回合回复
    // 已落库」的标记——活回合的 defer-reload 判定（dbHasTurnReply）靠它
    // 提前放行，回复不必等 30s 兜底 timer 才渲染。
    if (!enabled ||
        (activeTask.accumulatedContent.isEmpty &&
            activeTask.progressContent.isEmpty)) {
      return;
    }

    try {
      final metadata = <String, dynamic>{
        'trace_id': traceId,
        'is_partial': true,
        'flushed_content_length': activeTask.totalContentLength,
        'agent_id': agent.id,
        'agent_name': agent.name,
        if (activeTask.progressContent.isNotEmpty) ...{
          'progress_content': activeTask.progressContent,
          'collapsible': true,
          'collapsible_title': 'Details',
          'auto_collapse': true,
        },
        if (extraMetadata != null) ...extraMetadata,
      };

      final partialMessageId = await _db.upsertPartialStreamingMessage(
        existingMessageId: activeTask.partialMessageId,
        channelId: channelId,
        senderId: agent.id,
        senderName: agent.name,
        content: activeTask.accumulatedContent,
        replyToId: replyToId,
        status: 'streaming',
        metadata: metadata,
      );

      activeTask.recordFlush(partialMessageId);
      onFlushed?.call(partialMessageId);

      LoggerService().debug(
        'Flushed streaming content: ${activeTask.totalContentLength} '
        'bytes (answer=${activeTask.accumulatedContent.length}, '
        'progress=${activeTask.progressContent.length}) for task $traceId',
        tag: 'StreamingFlushHelper',
      );
    } catch (e) {
      LoggerService().warning(
        'Failed to flush streaming content for task $traceId',
        tag: 'StreamingFlushHelper',
        error: e,
      );
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Remove the partial row before the final message is persisted.
  Future<void> deletePartial() async {
    cancel();
    final id = activeTask.partialMessageId;
    if (id == null) return;
    try {
      await _db.deleteMessage(id);
    } catch (e) {
      LoggerService().warning(
        'Failed to delete partial streaming message $id',
        tag: 'StreamingFlushHelper',
        error: e,
      );
    }
    activeTask.partialMessageId = null;
  }

  /// Fire-and-forget delete used from sync cancel handlers.
  void deletePartialUnawaited() {
    cancel();
    final id = activeTask.partialMessageId;
    if (id == null) return;
    unawaited(_db.deleteMessage(id).catchError((Object e) {
      LoggerService().warning(
        'Failed to delete partial streaming message $id',
        tag: 'StreamingFlushHelper',
        error: e,
      );
    }));
    activeTask.partialMessageId = null;
  }
}

/// Build the final peer-protocol assistant content, including cancel cases.
String buildPeerFinalContent({
  required String answerContent,
  required String progressContent,
  required String accumulatedContent,
  required String resultContent,
  required bool wasCancelled,
}) {
  if (wasCancelled) {
    if (answerContent.isNotEmpty) {
      return '$answerContent\n\n[Stopped]';
    }
    if (accumulatedContent.isNotEmpty) {
      return '$accumulatedContent\n\n[Stopped]';
    }
    // Progress-only or no chunks yet: always leave a visible marker so
    // loadMessages cannot look like "no reply".
    return resultContent.isNotEmpty ? resultContent : '[Stopped]';
  }

  if (answerContent.isNotEmpty) return answerContent;
  // Progress-only turns keep content empty so MessageBubble renders
  // progress_content alone.
  if (progressContent.isNotEmpty) return '';
  if (accumulatedContent.isNotEmpty) return accumulatedContent;
  if (resultContent.isNotEmpty) return resultContent;
  return 'Task completed';
}
