import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';

/// 远端读缓存的内容寻址层（docs/storage_protocol_spec.md §7，方案 §6.4）。
///
/// 布局：`<store>/.cas/blobs/<sha256>` + `.cas/index.json`。
/// 仅服务他端共享区读取；本机正式区是真实文件树，不经本类写入。
/// `synced=false` 的 blob 不可 LRU 淘汰（防御性；生产读路径写入为 `synced: true`）。
class LocalCas {
  LocalCas({required Directory storeRoot})
      : _blobsDir = Directory(p.join(storeRoot.path, '.cas', 'blobs')),
        _indexFile = File(p.join(storeRoot.path, '.cas', 'index.json'));

  static const _tag = 'LocalCas';
  static const defaultCapBytes = 500 * 1024 * 1024; // 500MB（决策 6）

  final Directory _blobsDir;
  final File _indexFile;
  final _log = LoggerService();

  Map<String, Map<String, dynamic>>? _index;

  // ────────────────────────────── 读写 ──

  /// 写入内容（按 hash 去重，已存在直接复用）。返回 blob 文件。
  Future<File> put(Uint8List bytes, {bool synced = false}) async {
    final hash = crypto.sha256.convert(bytes).toString();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw ArgumentError('invalid content sha256');
    }
    await _blobsDir.create(recursive: true);
    final blob = File(p.join(_blobsDir.path, hash));
    final index = await _loadIndex();
    if (!await blob.exists()) {
      final tmp = File('${blob.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(blob.path);
    }
    index[hash] = {
      'size': bytes.length,
      'synced': synced || (index[hash]?['synced'] == true),
      'last_used': DateTime.now().millisecondsSinceEpoch,
    };
    await _saveIndex();
    return blob;
  }

  /// 已存在的 blob。
  Future<File?> get(String sha256) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
    final blob = File(p.join(_blobsDir.path, sha256));
    if (!await blob.exists()) return null;
    await touch(sha256);
    return blob;
  }

  /// 把 blob 物化到目标路径（优先硬链接零拷贝，失败回退复制）。
  Future<File> materialize(String sha256, String targetPath) async {
    final blob = File(p.join(_blobsDir.path, sha256));
    if (!await blob.exists()) {
      throw StateError('blob missing: $sha256');
    }
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    try {
      // Link(目标路径).create(指向的已有文件)
      await Link(targetPath).create(blob.path);
    } catch (_) {
      await blob.copy(targetPath);
    }
    await touch(sha256);
    return target;
  }

  Future<void> touch(String sha256) async {
    final index = await _loadIndex();
    final entry = index[sha256];
    if (entry == null) return;
    entry['last_used'] = DateTime.now().millisecondsSinceEpoch;
    // touch 高频，沿用下一次 _saveIndex 批量落盘；此处直接保存保证语义
    await _saveIndex();
  }

  // ────────────────────────────── 淘汰 ──

  Future<int> totalBytes() async {
    var total = 0;
    for (final e in (await _loadIndex()).values) {
      total += e['size'] as int? ?? 0;
    }
    return total;
  }

  /// LRU 淘汰至容量内：**只淘汰 synced 的 blob**。
  /// 返回释放字节数。
  Future<int> evict({int capBytes = defaultCapBytes}) async {
    final index = await _loadIndex();
    var total = 0;
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final e in index.entries) {
      total += e.value['size'] as int? ?? 0;
      entries.add(e);
    }
    if (total <= capBytes) return 0;

    // 最久未用优先，仅 synced 可淘汰
    entries.sort((a, b) => (a.value['last_used'] as int? ?? 0)
        .compareTo(b.value['last_used'] as int? ?? 0));
    var freed = 0;
    for (final e in entries) {
      if (total <= capBytes) break;
      if (e.value['synced'] != true) continue;
      final blob = File(p.join(_blobsDir.path, e.key));
      if (await blob.exists()) await blob.delete();
      index.remove(e.key);
      final size = e.value['size'] as int? ?? 0;
      total -= size;
      freed += size;
    }
    if (freed > 0) {
      _log.info('evicted $freed bytes from CAS', tag: _tag);
      await _saveIndex();
    }
    return freed;
  }

  /// 移除索引中已不存在的 blob 记录（自愈）。
  Future<void> pruneIndex() async {
    final index = await _loadIndex();
    final stale = <String>[];
    for (final hash in index.keys) {
      if (!await File(p.join(_blobsDir.path, hash)).exists()) {
        stale.add(hash);
      }
    }
    for (final hash in stale) {
      index.remove(hash);
    }
    if (stale.isNotEmpty) await _saveIndex();
  }

  // ────────────────────────────── 持久化 ──

  Future<Map<String, Map<String, dynamic>>> _loadIndex() async {
    final cached = _index;
    if (cached != null) return cached;
    if (!await _indexFile.exists()) {
      return _index = <String, Map<String, dynamic>>{};
    }
    try {
      final decoded = jsonDecode(await _indexFile.readAsString()) as Map;
      return _index = decoded.map((k, v) =>
          MapEntry(k as String, (v as Map).cast<String, dynamic>()));
    } catch (_) {
      return _index = <String, Map<String, dynamic>>{};
    }
  }

  Future<void> _saveIndex() async {
    await _indexFile.parent.create(recursive: true);
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(_index));
    await tmp.rename(_indexFile.path);
  }
}
