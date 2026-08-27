import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/inference_log_entry.dart';
import 'package:shepaw/models/trace_models.dart';
import 'package:shepaw/services/inference_log_catalog.dart';
import 'package:shepaw/services/log_file_parser.dart';
import 'package:shepaw/services/logger_service.dart';

void main() {
  group('LogFileParser', () {
    test('parses header, error, and stack continuation', () {
      const raw = '''
[2026-08-15 07:16:00.123] [ERROR] [AgentMessaging] send failed
Error: SocketException: Connection refused
StackTrace: #0 AgentMessagingService.send
#1 ChatController.send
[2026-08-15 07:16:01.000] [INFO] [Logger] next line
''';
      final entries = LogFileParser.parse(raw);
      expect(entries, hasLength(2));
      expect(entries[0].level, LogLevel.error);
      expect(entries[0].tag, 'AgentMessaging');
      expect(entries[0].message, 'send failed');
      expect(entries[0].error, 'SocketException: Connection refused');
      expect(entries[0].stackTrace, contains('ChatController.send'));
      expect(entries[1].level, LogLevel.info);
      expect(entries[1].message, 'next line');
    });

    test('parses lines without a tag', () {
      const raw = '[2026-08-15 07:16:00.123] [WARNING] disk almost full\n';
      final entries = LogFileParser.parse(raw);
      expect(entries, hasLength(1));
      expect(entries.single.tag, isNull);
      expect(entries.single.level, LogLevel.warning);
      expect(entries.single.message, 'disk almost full');
    });
  });

  group('LogCatalog', () {
    final logs = [
      LogEntry(
        timestamp: DateTime(2026, 8, 15, 7, 1),
        level: LogLevel.info,
        message: 'started',
        tag: 'Boot',
      ),
      LogEntry(
        timestamp: DateTime(2026, 8, 15, 7, 2),
        level: LogLevel.error,
        message: 'send failed',
        tag: 'Agent',
        error: 'timeout',
      ),
      LogEntry(
        timestamp: DateTime(2026, 8, 15, 7, 3),
        level: LogLevel.warning,
        message: 'slow path',
        tag: 'Agent',
      ),
    ];

    test('problemsOnly keeps error and warning', () {
      final filtered = LogCatalog.filter(logs, problemsOnly: true);
      expect(filtered.map((e) => e.level), [LogLevel.error, LogLevel.warning]);
    });

    test('minLevel is at-least, not exact', () {
      final filtered =
          LogCatalog.filter(logs, minLevel: LogLevel.warning);
      expect(filtered.map((e) => e.level), [LogLevel.error, LogLevel.warning]);
    });

    test('query matches message, tag, and error', () {
      expect(LogCatalog.filter(logs, query: 'timeout').single.message,
          'send failed');
      expect(LogCatalog.filter(logs, query: 'boot').single.tag, 'Boot');
    });

    test('mergeNewestFirst dedupes and sorts', () {
      final disk = [
        logs[1],
        LogEntry(
          timestamp: DateTime(2026, 8, 15, 6, 59),
          level: LogLevel.debug,
          message: 'older disk line',
          tag: 'Logger',
        ),
      ];
      final merged = LogCatalog.mergeNewestFirst(logs, disk);
      expect(merged.first.message, 'slow path');
      expect(merged.where((e) => e.message == 'send failed'), hasLength(1));
      expect(merged.last.message, 'older disk line');
    });
  });

  group('InferenceLogCatalog', () {
    test('live overlay wins and errors are searchable', () {
      final live = InferenceLogEntry(
        id: 's1',
        startTime: DateTime(2026, 8, 15, 8),
        agentId: 'a1',
        agentName: 'She',
        model: 'gpt-4',
        executionMode: 'local_multi_round',
        userMessage: 'hello',
        status: InferenceStatus.error,
      )..errorMessage = 'provider 401';

      final persisted = [
        TraceEntry(
          id: 's1',
          agentName: 'She',
          userMessage: 'hello',
          status: InferenceStatus.completed,
          startTime: DateTime(2026, 8, 15, 8),
          createdAt: DateTime(2026, 8, 15, 8),
        ),
        TraceEntry(
          id: 's2',
          agentName: 'Remote',
          model: 'claude',
          executionMode: 'remote_acp',
          userMessage: 'summarize this',
          startTime: DateTime(2026, 8, 15, 7),
          createdAt: DateTime(2026, 8, 15, 7),
        ),
      ];

      final merged = InferenceLogCatalog.merge(
        live: [live],
        persisted: persisted,
      );
      expect(merged, hasLength(2));
      expect(merged.first.id, 's1');
      expect(merged.first.status, InferenceStatus.error);
      expect(merged.first.live, isNotNull);

      final problems = InferenceLogCatalog.filter(merged, problemsOnly: true);
      expect(problems.single.id, 's1');

      final query = InferenceLogCatalog.filter(merged, query: 'summarize');
      expect(query.single.id, 's2');
    });

    test('merge skips peer connection and delivery traces', () {
      final persisted = [
        TraceEntry(
          id: 'llm',
          agentName: 'She',
          userMessage: 'hello',
          startTime: DateTime(2026, 8, 28, 0, 14),
          createdAt: DateTime(2026, 8, 28, 0, 14),
        ),
        TraceEntry(
          id: 'peer-conn',
          agentName: '家里的 Windows',
          userMessage: 'Connect 家里的 Windows',
          executionMode: 'peer_noise_handshake',
          traceRole: 'peer_connection',
          status: InferenceStatus.error,
          errorMessage: 'Bad state: No available endpoint for 家里的 Windows',
          startTime: DateTime(2026, 8, 28, 0, 14, 10),
          createdAt: DateTime(2026, 8, 28, 0, 14, 10),
        ),
        TraceEntry(
          id: 'peer-dm',
          agentName: 'peer_device',
          userMessage: 'hi',
          executionMode: 'peer_human_dm',
          traceRole: 'peer_message_delivery',
          startTime: DateTime(2026, 8, 28, 0, 13),
          createdAt: DateTime(2026, 8, 28, 0, 13),
        ),
      ];

      final merged = InferenceLogCatalog.merge(
        live: const [],
        persisted: persisted,
      );
      expect(merged.map((e) => e.id), ['llm']);
    });
  });
}
