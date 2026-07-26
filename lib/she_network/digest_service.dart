import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../services/she_memory_db_service.dart';
import '../services/she_service.dart';
import 'exchange_settings.dart';
import 'she_network_protocol.dart';

/// 本机蒸馏摘要生成（方案 §8.2）：从 she_memory 抽短句，按类别开关过滤。
///
/// 不做 LLM 调用——用本地已有键值拼装可交换摘要，保证确定性与可测性。
class DigestService {
  DigestService._();
  static final DigestService instance = DigestService._();

  final _log = LoggerService();
  static const _tag = 'Digest';

  /// 生成当前周期可外发的摘要条目。
  Future<List<DigestEntry>> buildOutgoing({ExchangeSettings? settings}) async {
    final cfg = settings ?? await ExchangeSettings.load();
    if (!cfg.enabled) return const [];

    final entries = <DigestEntry>[];
    try {
      final mem = SheMemoryDbService.instance;
      final soul = (await mem.getSheMemory('soul'))?.trim() ?? '';
      final ltm = (await mem.getSheMemory('long_term_memory'))?.trim() ?? '';
      final notes = (await mem.getSheMemory('self_notes'))?.trim() ?? '';

      if (cfg.kinds.contains(DigestKind.preference) && soul.isNotEmpty) {
        entries.add(DigestEntry(
          kind: DigestKind.preference,
          text: _clip('偏好/自我认知：$soul'),
          confidence: 0.7,
        ));
      }
      if (cfg.kinds.contains(DigestKind.fact) && ltm.isNotEmpty) {
        entries.add(DigestEntry(
          kind: DigestKind.fact,
          text: _clip('事实：$ltm'),
          confidence: 0.75,
        ));
      }
      if (cfg.kinds.contains(DigestKind.ongoing) && notes.isNotEmpty) {
        entries.add(DigestEntry(
          kind: DigestKind.ongoing,
          text: _clip('进行中：$notes'),
          confidence: 0.65,
        ));
      }
    } catch (e) {
      _log.warning('digest build failed: $e', tag: _tag);
    }
    return entries;
  }

  /// 当前周期标签（ISO 周）。
  String currentPeriod() {
    final now = DateTime.now().toUtc();
    final start = now.subtract(Duration(days: now.weekday - 1));
    final end = start.add(const Duration(days: 6));
    String fmt(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return '${fmt(start)}/${fmt(end)}';
  }

  /// 本机 she 显示名（多设备命名：优先 agents 表自定义名）。
  Future<String> localSheName({String localizedDefault = 'She'}) async {
    try {
      final db = await LocalDatabaseService().database;
      final rows = await db.query(
        'agents',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [SheService.sheId],
        limit: 1,
      );
      final stored = rows.isEmpty ? null : rows.first['name'] as String?;
      return SheService.resolveDisplayName(stored, localizedDefault);
    } catch (_) {
      return localizedDefault;
    }
  }

  static String _clip(String s, [int max = 280]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }
}
