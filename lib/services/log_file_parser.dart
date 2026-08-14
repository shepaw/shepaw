import 'logger_service.dart';

/// Parses disk log files written by [LoggerService].
///
/// Line format:
/// `[yyyy-MM-dd HH:mm:ss.SSS] [LEVEL] [tag] message`
/// followed by optional `Error:` / `StackTrace:` continuation lines.
class LogFileParser {
  LogFileParser._();

  static final _header = RegExp(
    r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)\] \[([A-Z]+)\](?: \[([^\]]+)\])? (.*)$',
  );

  static List<LogEntry> parse(String content) {
    if (content.isEmpty) return const [];
    return parseLines(content.split('\n'));
  }

  static List<LogEntry> parseLines(Iterable<String> lines) {
    final entries = <LogEntry>[];
    _Pending? current;

    void flush() {
      final pending = current;
      if (pending == null) return;
      entries.add(pending.toEntry());
      current = null;
    }

    for (final raw in lines) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) continue;
      if (line.startsWith('==========') && line.endsWith('==========')) {
        flush();
        continue;
      }

      final match = _header.firstMatch(line);
      if (match != null) {
        flush();
        current = _Pending(
          timestamp: _parseTimestamp(match.group(1)!),
          level: parseLevel(match.group(2)!),
          tag: match.group(3),
          message: match.group(4) ?? '',
        );
        continue;
      }

      if (current == null) continue;

      if (line.startsWith('Error: ')) {
        current.error = line.substring(7);
      } else if (line.startsWith('StackTrace: ')) {
        current.stackTrace = line.substring(12);
      } else if (current.stackTrace != null) {
        current.stackTrace = '${current.stackTrace}\n$line';
      } else if (current.error != null) {
        current.error = '${current.error}\n$line';
      } else {
        current.message = '${current.message}\n$line';
      }
    }

    flush();
    return entries;
  }

  static LogLevel parseLevel(String raw) {
    switch (raw.toUpperCase()) {
      case 'DEBUG':
        return LogLevel.debug;
      case 'INFO':
        return LogLevel.info;
      case 'WARNING':
        return LogLevel.warning;
      case 'ERROR':
        return LogLevel.error;
      default:
        return LogLevel.info;
    }
  }

  static DateTime _parseTimestamp(String raw) {
    return DateTime.tryParse(raw.replaceFirst(' ', 'T')) ?? DateTime.now();
  }
}

class _Pending {
  _Pending({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String? tag;
  String message;
  String? error;
  String? stackTrace;

  LogEntry toEntry() => LogEntry(
        timestamp: timestamp,
        level: level,
        message: message,
        tag: tag,
        error: error,
        stackTrace: stackTrace,
      );
}

/// Filters and ranks log entries for the system-log viewer.
class LogCatalog {
  LogCatalog._();

  static List<LogEntry> filter(
    Iterable<LogEntry> logs, {
    LogLevel? minLevel,
    String? tag,
    String? query,
    bool problemsOnly = false,
  }) {
    final q = query?.trim().toLowerCase();
    return logs.where((log) {
      if (problemsOnly &&
          log.level != LogLevel.error &&
          log.level != LogLevel.warning) {
        return false;
      }
      if (minLevel != null && log.level.severity < minLevel.severity) {
        return false;
      }
      if (tag != null && log.tag != tag) return false;
      if (q == null || q.isEmpty) return true;
      return log.message.toLowerCase().contains(q) ||
          (log.tag?.toLowerCase().contains(q) ?? false) ||
          (log.error?.toLowerCase().contains(q) ?? false) ||
          (log.stackTrace?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  /// Newest first. Dedupes memory+disk copies of the same write.
  static List<LogEntry> mergeNewestFirst(
    Iterable<LogEntry> memory,
    Iterable<LogEntry> disk,
  ) {
    final seen = <String>{};
    final merged = <LogEntry>[];

    void addAll(Iterable<LogEntry> source) {
      for (final entry in source) {
        final key = entry.dedupeKey;
        if (!seen.add(key)) continue;
        merged.add(entry);
      }
    }

    addAll(memory);
    addAll(disk);
    merged.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return merged;
  }
}
