import '../services/local_database_service.dart';
import 'she_network_protocol.dart';

/// 外部记忆条目（来源设备隔离、追加式）。
class ExternalMemory {
  ExternalMemory({
    required this.id,
    required this.fromDevice,
    required this.kind,
    required this.text,
    required this.confidence,
    required this.period,
    required this.receivedAtMs,
  });

  final int id;
  final String fromDevice;
  final String kind;
  final String text;
  final double confidence;
  final String period;
  final int receivedAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'from_device': fromDevice,
        'kind': kind,
        'text': text,
        'confidence': confidence,
        'period': period,
        'received_at': receivedAtMs,
      };
}

/// `external_memories` 表访问。
class ExternalMemoryStore {
  ExternalMemoryStore._();
  static final ExternalMemoryStore instance = ExternalMemoryStore._();

  Future<void> appendOffer({
    required String fromDevice,
    required String period,
    required List<DigestEntry> entries,
  }) async {
    if (entries.isEmpty) return;
    final db = await LocalDatabaseService().database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final e in entries) {
      if (e.text.trim().isEmpty) continue;
      batch.insert('external_memories', <String, dynamic>{
        'from_device': fromDevice,
        'kind': e.kind,
        'text': e.text.trim(),
        'confidence': e.confidence,
        'period': period,
        'received_at': now,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<ExternalMemory>> list({String? fromDevice, int limit = 100}) async {
    final db = await LocalDatabaseService().database;
    final rows = await db.query(
      'external_memories',
      where: fromDevice != null ? 'from_device = ?' : null,
      whereArgs: fromDevice != null ? [fromDevice] : null,
      orderBy: 'received_at DESC',
      limit: limit,
    );
    return [
      for (final r in rows)
        ExternalMemory(
          id: r['id'] as int,
          fromDevice: r['from_device'] as String,
          kind: r['kind'] as String,
          text: r['text'] as String,
          confidence: (r['confidence'] as num).toDouble(),
          period: r['period'] as String? ?? '',
          receivedAtMs: r['received_at'] as int,
        ),
    ];
  }

  Future<Map<String, int>> countsByDevice() async {
    final db = await LocalDatabaseService().database;
    final rows = await db.rawQuery(
        'SELECT from_device, COUNT(*) AS c FROM external_memories GROUP BY from_device');
    return {
      for (final r in rows)
        r['from_device'] as String: r['c'] as int,
    };
  }
}
