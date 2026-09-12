import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'local_store.dart' show StoreException;
import 'store_protocol.dart';

/// 单次远端 `read` / `versions.read` 的结果。
class StoreReadChunk {
  StoreReadChunk({
    required this.bytes,
    required this.fileSize,
    required this.eof,
    this.binary = false,
  });

  final Uint8List bytes;
  final int fileSize;
  final bool eof;
  final bool binary;

  /// 兼容 JSON `{data: base64}`、二进制回复 `{data: Uint8List}`、以及
  /// loopback `{_bin: Uint8List}`。
  static StoreReadChunk fromResult(Map<String, dynamic> res) {
    if (res.containsKey('_error')) {
      throw StoreException(
        res['_error'] as String? ?? StoreError.internal,
        res['message'] as String? ?? '',
      );
    }
    final eof = res['eof'] == true;
    final size = (res['size'] as num?)?.toInt() ?? 0;
    final raw = res['_bin'] ?? res['data'];
    if (raw is Uint8List) {
      return StoreReadChunk(
        bytes: raw,
        fileSize: size,
        eof: eof,
        binary: res['_encoding'] == StoreTransfer.encodingBin ||
            res.containsKey('_bin'),
      );
    }
    if (raw is String) {
      return StoreReadChunk(
        bytes: Uint8List.fromList(base64Decode(raw)),
        fileSize: size,
        eof: eof,
      );
    }
    throw StateError('read result missing data');
  }
}

typedef StoreChunkFetch = Future<StoreReadChunk> Function({
  required int offset,
  required int length,
  required bool binary,
});

class _NeedJsonFallback implements Exception {
  const _NeedJsonFallback();
}

/// 远端文件泵：优先 `encoding=bin` + 256KB，旧对端回退 JSON 64KB；
/// 已知 [fileSize] 后按滑动窗口并发拉取并**按 offset 重排写出**。
class StoreRemoteFetcher {
  StoreRemoteFetcher._();

  static Future<void> pump({
    required int fileSize,
    required StoreChunkFetch fetch,
    required void Function(Uint8List chunk) onChunk,
    void Function(int done, int total)? onProgress,
    int window = StoreTransfer.pipelineWindow,
    bool preferBinary = true,
  }) async {
    if (fileSize <= 0) {
      onProgress?.call(0, 0);
      return;
    }

    var binary = preferBinary;
    var chunkSize =
        binary ? StoreTransfer.binaryChunk : StoreTransfer.jsonChunk;

    Future<StoreReadChunk> fetchSafe(int offset, int length) async {
      try {
        return await fetch(
          offset: offset,
          length: length,
          binary: binary,
        );
      } on StoreException catch (e) {
        if (binary && e.code == StoreError.badOp) {
          throw const _NeedJsonFallback();
        }
        rethrow;
      }
    }

    StoreReadChunk first;
    try {
      first = await fetchSafe(0, min(chunkSize, fileSize));
    } on _NeedJsonFallback {
      binary = false;
      chunkSize = StoreTransfer.jsonChunk;
      first = await fetchSafe(0, min(chunkSize, fileSize));
    }

    if (!first.binary) {
      binary = false;
      chunkSize = StoreTransfer.jsonChunk;
    }
    // 旧节点可能悄悄把 256KB 请求截成 64KB。
    if (!first.eof &&
        first.bytes.isNotEmpty &&
        first.bytes.length < chunkSize) {
      chunkSize = first.bytes.length;
    }

    onChunk(first.bytes);
    var done = first.bytes.length;
    onProgress?.call(done, fileSize);
    if (first.eof || done >= fileSize) return;

    var nextOffset = done;
    final inFlight = <int, Future<StoreReadChunk>>{};
    final ready = <int, StoreReadChunk>{};

    void launch(int offset) {
      final length = min(chunkSize, fileSize - offset);
      if (length <= 0) return;
      inFlight[offset] = fetch(
        offset: offset,
        length: length,
        binary: binary,
      );
    }

    void fill() {
      while (inFlight.length < window && nextOffset < fileSize) {
        launch(nextOffset);
        nextOffset += chunkSize;
      }
    }

    fill();
    var expect = done;
    while (done < fileSize) {
      final queued = ready.remove(expect);
      if (queued != null) {
        onChunk(queued.bytes);
        done += queued.bytes.length;
        expect += queued.bytes.length;
        onProgress?.call(done, fileSize);
        if (queued.eof || done >= fileSize) break;
        fill();
        continue;
      }
      if (inFlight.isEmpty) {
        throw StateError('download stalled at $done/$fileSize');
      }
      final completed = await Future.any(inFlight.entries.map((e) async {
        final chunk = await e.value;
        return MapEntry(e.key, chunk);
      }));
      inFlight.remove(completed.key);
      ready[completed.key] = completed.value;
    }
  }
}
