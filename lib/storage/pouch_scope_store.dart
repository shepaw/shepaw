/// 按 scope 读写 hub 的 v3 袋子（[G4]）。
///
/// hub 的手机帧只认 `scope` + `pouch_id`（`crates/pouch/src/protocol.rs`）。
/// 这里把帧的收发收在一处，调用方只给 [PouchScope] 和路径，不再自己拼
/// `space`/`device`，也不自己拼地址（地址一律走 [PouchV2Uri]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../peer/services/peer_connection_manager.dart';
import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_session.dart';
import 'store_protocol.dart';

/// 与 hub 交换 v3 帧的传输层。测试里换成假实现，不碰网络。
abstract class PouchScopeTransport {
  /// 列 scope 下 `prefix` 开头的条目（hub 返回的是扁平的完整路径）。
  Future<List<StoreEntry>> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
  });

  /// 读整份文件；不存在返回 null。
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  });

  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
  });

  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  });
}

/// 走配对通道给 hub 发 `pouch` 帧（协议 v2：scope + pouch_id）。
class HubPouchScopeTransport implements PouchScopeTransport {
  HubPouchScopeTransport({
    required this.peerId,
    required Future<bool> Function(String peerId, Map<String, dynamic> frame)
        send,
    Stream<PeerControlEvent>? events,
    Duration timeout = const Duration(seconds: 20),
  })  : _send = send,
        _events = events ?? PeerConnectionManager.instance.controlEvents,
        _timeout = timeout;

  /// 主机那条配对的 peer id。
  final String peerId;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame) _send;
  final Stream<PeerControlEvent> _events;
  final Duration _timeout;
  final _uuid = const Uuid();

  /// 单块大小：hub 的暂存上限 20 MB，这里取常用的 64 KiB。
  static const chunkSize = 64 * 1024;

  @override
  Future<List<StoreEntry>> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
  }) async {
    final data = await _call(
      op: StoreOp.list,
      pouchId: pouchId,
      scope: scope,
      fields: <String, dynamic>{
        if (prefix != null && prefix.isNotEmpty) 'path': prefix,
        'limit': limit,
      },
    );
    final raw = data['entries'] as List? ?? const [];
    return <StoreEntry>[
      for (final item in raw)
        if (item is Map) StoreEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final Map<String, dynamic> data;
      try {
        data = await _call(
          op: StoreOp.read,
          pouchId: pouchId,
          scope: scope,
          fields: <String, dynamic>{
            'path': path,
            'offset': offset,
            'length': chunkSize,
          },
        );
      } on StoreException catch (e) {
        if (e.code == StoreError.notFound) return null;
        rethrow;
      }
      final encoded = data['data'] as String? ?? '';
      final bytes = encoded.isEmpty ? Uint8List(0) : base64Decode(encoded);
      if (bytes.isNotEmpty) out.add(bytes);
      final size = (data['size'] as num?)?.toInt() ?? 0;
      final eof = data['eof'] == true;
      offset += bytes.length;
      if (eof || bytes.isEmpty || offset >= size) break;
    }
    return out.takeBytes();
  }

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
  }) async {
    final normalized = normalizeStorePath(path);
    final begin = await _call(
      op: StoreOp.writeBegin,
      pouchId: pouchId,
      scope: scope,
      fields: <String, dynamic>{
        'path': normalized,
        'size': bytes.length,
      },
    );
    final uploadId = (begin['upload_id'] as String?)?.trim() ?? '';
    if (uploadId.isEmpty) {
      throw StoreException(StoreError.internal, 'write.begin 没有 upload_id');
    }
    var offset = 0;
    do {
      final end = (offset + chunkSize) > bytes.length
          ? bytes.length
          : offset + chunkSize;
      await _call(
        op: StoreOp.writeChunk,
        pouchId: pouchId,
        scope: scope,
        fields: <String, dynamic>{
          'upload_id': uploadId,
          'offset': offset,
          'data': base64Encode(bytes.sublist(offset, end)),
        },
      );
      offset = end;
    } while (offset < bytes.length);
    await _call(
      op: StoreOp.commit,
      pouchId: pouchId,
      scope: scope,
      fields: <String, dynamic>{
        'upload_ids': [uploadId],
      },
    );
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    await _call(
      op: StoreOp.delete,
      pouchId: pouchId,
      scope: scope,
      fields: <String, dynamic>{'path': normalizeStorePath(path)},
    );
  }

  Future<Map<String, dynamic>> _call({
    required String op,
    required String pouchId,
    required PouchScope scope,
    Map<String, dynamic> fields = const {},
  }) async {
    final reqId = 'p-${_uuid.v4()}';
    final done = Completer<Map<String, dynamic>>();
    final sub = _events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId) return;
      final type = event.type;
      if (type != 'pouch') return;
      final data = event.data;
      if (data['req_id'] != reqId) return;
      final responseOp = data['op'] as String?;
      if (responseOp == StoreOp.result) {
        final payload = data['data'];
        done.complete(payload is Map
            ? Map<String, dynamic>.from(payload)
            : <String, dynamic>{});
      } else if (responseOp == StoreOp.error) {
        done.completeError(StoreException(
          (data['code'] as String?)?.trim().isNotEmpty == true
              ? data['code'] as String
              : StoreError.internal,
          (data['message'] as String?) ?? '',
        ));
      }
    });
    try {
      final sent = await _send(peerId, <String, dynamic>{
        'type': kStoreControlType,
        'ns': kStoreControlType,
        'op': op,
        'v': 2,
        'req_id': reqId,
        'pouch_id': pouchId,
        'scope': scope.id,
        ...fields,
      });
      if (!sent) {
        throw StoreException(StoreError.masterOffline, '连不上这台主机');
      }
      return await done.future.timeout(
        _timeout,
        onTimeout: () => throw StoreException(
          StoreError.masterOffline,
          '$op 超时',
        ),
      );
    } finally {
      await sub.cancel();
    }
  }
}

/// 当前登录的袋子 + 主机通道；没登录返回 null。
Future<HubPouchScopeTransport?> activeHubPouchTransport() async {
  final session = await PouchSessionStore.readActive();
  if (session == null || session.hostPeerId.isEmpty) return null;
  return HubPouchScopeTransport(
    peerId: session.hostPeerId,
    send: (peerId, frame) =>
        PeerConnectionManager.instance.sendControl(peerId, frame),
  );
}

/// scope 的读写出入口：地址从这里格式化，别处不许拼字符串。
class PouchScopeStore {
  PouchScopeStore({required this.transport, required this.pouchId});

  final PouchScopeTransport transport;

  /// 当前袋子的 id（帧里的 `pouch_id`，也是地址的第一段）。
  final String pouchId;

  /// 列 `scope` 下 [path] 这一层的子项（目录折叠成一条）。
  Future<List<StoreEntry>> listChildren(
    PouchScope scope, {
    String path = '',
    int limit = 1000,
  }) async {
    final prefix = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final flat = await transport.list(
      pouchId: pouchId,
      scope: scope,
      prefix: prefix.isEmpty ? null : prefix,
      limit: limit,
    );
    return foldScopeListing(flat, path: prefix);
  }

  /// 读一份文件；不存在返回 null。
  Future<Uint8List?> read(PouchScope scope, String path) =>
      transport.read(pouchId: pouchId, scope: scope, path: path);

  /// 写一份文件，返回它的 v3 地址。
  Future<String> write(PouchScope scope, String path, Uint8List bytes) async {
    final normalized = scopeStorePath(path);
    await transport.write(
      pouchId: pouchId,
      scope: scope,
      path: normalized,
      bytes: bytes,
    );
    return uriFor(scope, normalized).format();
  }

  Future<void> delete(PouchScope scope, String path) => transport.delete(
        pouchId: pouchId,
        scope: scope,
        path: scopeStorePath(path),
      );

  /// 这只袋子里某个 scope 的地址。
  PouchV2Uri uriFor(PouchScope scope, [String path = '']) =>
      PouchV2Uri(pouchId: pouchId, scope: scope.id, path: path);
}

/// scope 里的路径：允许调用方带前导 `/`（从地址里抄来的），其余按 store
/// 路径规则规范化（拒绝穿越与点段）。
String scopeStorePath(String path) =>
    normalizeStorePath(path.trim().replaceAll(RegExp(r'^/+'), ''));

/// hub 的 `list` 回的是扁平路径；浏览器只要当前一层的子项。
///
/// - `docs/a.md` → 文件 `docs/a.md`；
/// - `docs/sub/b.md` → 目录 `docs/sub`；
/// - 与 `path` 不在同一层的条目丢掉。
List<StoreEntry> foldScopeListing(
  Iterable<StoreEntry> entries, {
  String path = '',
}) {
  final prefix = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  final dirs = <String, int>{};
  final files = <StoreEntry>[];
  for (final entry in entries) {
    final entryPath = entry.path.trim().replaceAll(RegExp(r'^/+'), '');
    if (entryPath.isEmpty) continue;
    final String rest;
    if (prefix.isEmpty) {
      rest = entryPath;
    } else if (entryPath == prefix) {
      continue;
    } else if (entryPath.startsWith('$prefix/')) {
      rest = entryPath.substring(prefix.length + 1);
    } else {
      continue;
    }
    if (rest.isEmpty) continue;
    final slash = rest.indexOf('/');
    if (slash < 0) {
      if (!entry.isDir) files.add(entry);
      continue;
    }
    final name = rest.substring(0, slash);
    final childPath = prefix.isEmpty ? name : '$prefix/$name';
    final mtime = dirs[childPath];
    if (mtime == null || entry.mtimeMs > mtime) {
      dirs[childPath] = entry.mtimeMs;
    }
  }
  final out = <StoreEntry>[
    for (final item in dirs.entries)
      StoreEntry(
        path: item.key,
        size: 0,
        sha256: '',
        mtimeMs: item.value,
        kind: 'dir',
      ),
    ...files,
  ]..sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.path.compareTo(b.path);
    });
  return out;
}
