import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the independent `agent_traces.db` SQLite database.
///
/// Completely isolated from the main `shepaw.db` — trace data
/// can be deleted or reset without affecting user data.
class TraceDatabaseService {
  static final TraceDatabaseService _instance = TraceDatabaseService._internal();
  factory TraceDatabaseService() => _instance;
  TraceDatabaseService._internal();

  Database? _database;

  static const int _version = 3;
  static const String _dbName = 'agent_traces.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'agent_traces',
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, _dbName);

    return await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE traces (
        id TEXT PRIMARY KEY,
        channel_id TEXT,
        agent_id TEXT,
        agent_name TEXT NOT NULL,
        provider TEXT,
        model TEXT,
        execution_mode TEXT,
        system_prompt TEXT,
        user_message TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'in_progress',
        error_message TEXT,
        start_time TEXT NOT NULL,
        end_time TEXT,
        duration_ms INTEGER,
        total_rounds INTEGER DEFAULT 0,
        total_tool_calls INTEGER DEFAULT 0,
        total_input_tokens INTEGER,
        total_output_tokens INTEGER,
        total_text_chars INTEGER DEFAULT 0,
        parent_trace_id TEXT,
        trace_role TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE trace_spans (
        id TEXT PRIMARY KEY,
        trace_id TEXT NOT NULL,
        parent_span_id TEXT,
        span_type TEXT NOT NULL,
        name TEXT,
        model TEXT,
        sequence_number INTEGER NOT NULL DEFAULT 0,
        start_time TEXT NOT NULL,
        end_time TEXT,
        duration_ms INTEGER,
        status TEXT NOT NULL DEFAULT 'in_progress',
        error_message TEXT,
        input_data TEXT,
        output_data TEXT,
        metadata TEXT,
        FOREIGN KEY (trace_id) REFERENCES traces(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('CREATE INDEX idx_traces_channel ON traces(channel_id)');
    await db.execute('CREATE INDEX idx_traces_agent ON traces(agent_id)');
    await db.execute('CREATE INDEX idx_traces_status ON traces(status)');
    await db.execute('CREATE INDEX idx_traces_start_time ON traces(start_time DESC)');
    await db.execute('CREATE INDEX idx_trace_spans_trace ON trace_spans(trace_id, sequence_number)');
    await db.execute('CREATE INDEX idx_trace_spans_type ON trace_spans(span_type)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE trace_spans ADD COLUMN model TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE traces ADD COLUMN parent_trace_id TEXT');
      await db.execute('ALTER TABLE traces ADD COLUMN trace_role TEXT');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_traces_parent ON traces(parent_trace_id)');
    }
  }

  /// Close the database connection (useful for testing or reset).
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// Delete the entire database file and reset. Does not affect main db.
  Future<void> deleteDatabase() async {
    await close();
    if (!kIsWeb) {
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _dbName);
      try {
        await databaseFactory.deleteDatabase(path);
      } catch (_) {}
    }
  }
}
