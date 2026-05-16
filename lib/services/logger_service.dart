import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

/// 日志级别
enum LogLevel {
  debug,
  info,
  warning,
  error,
}

/// 本地日志服务
///
/// P1: 日志记录和监控
class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  File? _logFile;
  bool _initialized = false;
  bool _logDirVerified = false;
  final List<LogEntry> _memoryLogs = [];
  static const int _maxMemoryLogs = 1000;
  static const int _maxLogFileSizeMB = 10;

  /// 初始化日志服务
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      _logFile = File('${logDir.path}/app_$dateStr.log');

      // 检查文件大小，如果超过限制则轮转
      if (await _logFile!.exists()) {
        final fileSize = await _logFile!.length();
        if (fileSize > _maxLogFileSizeMB * 1024 * 1024) {
          await _rotateLogFile();
        }
      }

      _initialized = true;
      info('LoggerService initialized', tag: 'Logger');
    } catch (e) {
      // Logger itself failed — fall back to print as last resort
      if (kDebugMode) print('Failed to initialize logger: $e');
    }
  }

  /// 轮转日志文件
  Future<void> _rotateLogFile() async {
    if (_logFile == null) return;

    try {
      final timestamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final newPath = '${_logFile!.path}.$timestamp.old';
      await _logFile!.rename(newPath);
      _logFile = File(_logFile!.path);
    } catch (e) {
      if (kDebugMode) print('Failed to rotate log file: $e');
    }
  }

  /// 写入日志
  Future<void> _writeLog(LogLevel level, String message, {String? tag, dynamic error, StackTrace? stackTrace}) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
    final levelStr = level.toString().split('.').last.toUpperCase();
    final tagStr = tag != null ? ' [$tag]' : '';

    var logMessage = '[$timestamp] [$levelStr]$tagStr $message';

    if (error != null) {
      logMessage += '\nError: $error';
    }

    if (stackTrace != null) {
      logMessage += '\nStackTrace: $stackTrace';
    }

    // 添加到内存日志
    _memoryLogs.add(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
    ));

    // 保持内存日志数量限制
    if (_memoryLogs.length > _maxMemoryLogs) {
      _memoryLogs.removeAt(0);
    }

    // debug 模式输出到控制台，release 模式只写文件
    if (kDebugMode) {
      print(logMessage);
    }

    // 写入文件
    if (_initialized && _logFile != null) {
      try {
        // 首次写入时确保日志目录存在（防止沙盒路径变化或目录被清理）
        if (!_logDirVerified) {
          final logDir = _logFile!.parent;
          if (!await logDir.exists()) {
            await logDir.create(recursive: true);
          }
          _logDirVerified = true;
        }
        await _logFile!.writeAsString('$logMessage\n', mode: FileMode.append);
      } catch (e) {
        if (kDebugMode) print('Failed to write log to file: $e');
      }
    }
  }

  /// Debug 日志
  void debug(String message, {String? tag}) {
    _writeLog(LogLevel.debug, message, tag: tag);
  }

  /// Info 日志
  void info(String message, {String? tag}) {
    _writeLog(LogLevel.info, message, tag: tag);
  }

  /// Warning 日志
  void warning(String message, {String? tag, dynamic error}) {
    _writeLog(LogLevel.warning, message, tag: tag, error: error);
  }

  /// Error 日志
  void error(String message, {String? tag, dynamic error, StackTrace? stackTrace}) {
    _writeLog(LogLevel.error, message, tag: tag, error: error, stackTrace: stackTrace);
  }

  /// 获取内存中的日志
  List<LogEntry> getMemoryLogs({LogLevel? level, String? tag}) {
    var logs = _memoryLogs.where((_) => true);
    if (level != null) {
      logs = logs.where((log) => log.level == level);
    }
    if (tag != null) {
      logs = logs.where((log) => log.tag == tag);
    }
    return logs.toList();
  }

  /// 获取所有已使用的 tag 列表
  List<String> getUsedTags() {
    return _memoryLogs
        .where((log) => log.tag != null)
        .map((log) => log.tag!)
        .toSet()
        .toList()
      ..sort();
  }

  /// 获取日志文件路径
  String? getLogFilePath() => _logFile?.path;

  /// 清除旧日志
  Future<void> clearOldLogs({int daysToKeep = 7}) async {
    if (_logFile == null) return;

    try {
      final logDir = _logFile!.parent;
      final files = await logDir.list().toList();
      final cutoffDate = DateTime.now().subtract(Duration(days: daysToKeep));

      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.log')) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoffDate)) {
            await entity.delete();
            info('Deleted old log file: ${entity.path}', tag: 'Logger');
          }
        }
      }
    } catch (e) {
      error('Failed to clear old logs', tag: 'Logger', error: e);
    }
  }

  /// 导出日志
  Future<String?> exportLogs() async {
    if (_logFile == null) return null;

    try {
      final tempDir = await getTemporaryDirectory();
      final exportFile = File('${tempDir.path}/logs_export_${DateTime.now().millisecondsSinceEpoch}.txt');

      // 读取所有日志文件
      final logDir = _logFile!.parent;
      final files = await logDir.list().toList();
      final logFiles = files.whereType<File>().where((f) => f.path.contains('.log')).toList();

      // 按时间排序
      logFiles.sort((a, b) => a.path.compareTo(b.path));

      // 合并所有日志
      final buffer = StringBuffer();
      for (final file in logFiles) {
        buffer.writeln('\n========== ${file.path} ==========\n');
        buffer.writeln(await file.readAsString());
      }

      await exportFile.writeAsString(buffer.toString());
      return exportFile.path;
    } catch (e) {
      error('Failed to export logs', tag: 'Logger', error: e);
      return null;
    }
  }
}

/// 日志条目
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? tag;
  final dynamic error;
  final StackTrace? stackTrace;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
  });

  String get levelString => level.toString().split('.').last.toUpperCase();

  String get timeString => DateFormat('HH:mm:ss').format(timestamp);
}
