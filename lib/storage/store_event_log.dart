import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// `.system/events.jsonl` 事件总线（spec §2.11 / §12）。
///
/// 无事件时 `events.list` 返回空列表与 `latest_seq: 0`。
class StoreEventLog {
  StoreEventLog(this.root)
      : _file = File(p.join(root.path, '.system', 'events.jsonl')),
        _seqFile = File(p.join(root.path, '.system', 'events.seq'));

  final Directory root;
  final File _file;
  final File _seqFile;
  int _latestSeq = 0;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (await _seqFile.exists()) {
      _latestSeq = int.tryParse((await _seqFile.readAsString()).trim()) ?? 0;
      return;
    }
    if (!await _file.exists()) return;
    try {
      await for (final line in _file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final seq = (decoded['seq'] as num?)?.toInt() ?? 0;
          if (seq > _latestSeq) _latestSeq = seq;
        }
      }
    } catch (_) {
      // 损坏的 jsonl：保留已解析的最大 seq。
    }
  }

  int get latestSeq => _latestSeq;

  Future<Map<String, dynamic>> append({
    required String kind,
    required String device,
    required String space,
    required String path,
    Map<String, dynamic>? detail,
  }) async {
    await load();
    _latestSeq += 1;
    final event = <String, dynamic>{
      'seq': _latestSeq,
      'kind': kind,
      'device': device,
      'space': space,
      'path': path,
      'uri': 'store://$space/$device/$path',
      'ts_ms': DateTime.now().millisecondsSinceEpoch,
      if (detail != null) 'detail': detail,
    };
    await _file.parent.create(recursive: true);
    await _file.writeAsString('${jsonEncode(event)}\n',
        mode: FileMode.append);
    await _seqFile.writeAsString('$_latestSeq');
    return event;
  }

  /// `seq > since`，升序；可选 [kind] 过滤。
  Future<({List<Map<String, dynamic>> events, int latestSeq})> list({
    int since = 0,
    int limit = 50,
    String? kind,
  }) async {
    await load();
    final cap = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    if (!await _file.exists()) {
      return (events: const <Map<String, dynamic>>[], latestSeq: _latestSeq);
    }
    final out = <Map<String, dynamic>>[];
    try {
      await for (final line in _file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (out.length >= cap) break;
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final event = Map<String, dynamic>.from(decoded);
        final seq = (event['seq'] as num?)?.toInt() ?? 0;
        if (seq <= since) continue;
        if (kind != null && kind.isNotEmpty && event['kind'] != kind) {
          continue;
        }
        out.add(event);
      }
    } catch (_) {
      // 部分损坏时返回已解析条目。
    }
    return (events: out, latestSeq: _latestSeq);
  }
}
