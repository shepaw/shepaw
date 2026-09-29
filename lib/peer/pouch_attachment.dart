import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/attachment_data.dart';
import '../services/local_database_service.dart';
import '../services/messaging/message_implicit_prompt.dart';
import '../storage/attachment_store_writer.dart';
import '../storage/pouch_role.dart';
import '../storage/runtime_paths.dart';
import '../storage/store_service.dart';
import 'services/peer_connection_manager.dart';

/// 客户端把回合附件交给主机。帧里只带编号，字节按片走。
class PouchAttachment {
  PouchAttachment._();

  static const beginType = 'pouch_file_begin';
  static const chunkType = 'pouch_file_chunk';
  static const endType = 'pouch_file_end';
  static const ackType = 'pouch_file_ack';

  static const controlTypes = <String>[
    beginType,
    chunkType,
    endType,
    ackType,
  ];
}

/// 附件落在哪一段 runtime 下。群用群族 id，单聊用 Agent。
class PouchAttachmentPlacement {
  PouchAttachmentPlacement._();

  static ({String ownerId, String channelId}) resolve({
    required String placement,
    required String agentId,
    required String channelId,
    String? parentGroupId,
  }) {
    if (placement == 'group') {
      return RuntimePaths.resolveStoreTarget(
        agentId: agentId.trim().isEmpty ? channelId : agentId,
        channelId: channelId,
        channelType: 'group',
        parentGroupId: parentGroupId,
      );
    }
    return RuntimePaths.resolveStoreTarget(
      agentId: agentId,
      channelId: channelId.trim().isEmpty ? null : channelId,
    );
  }
}

typedef PouchBytesStore = Future<String> Function(
  Uint8List bytes, {
  required String ownerId,
  required String channelId,
});

/// 主机上一次上传的装配与领取。测试注入 [PouchBytesStore]，不碰网络。
class PouchAttachmentDesk {
  PouchAttachmentDesk();

  static final PouchAttachmentDesk instance = PouchAttachmentDesk();

  static const _maxInflight = 8;
  static const _maxStored = 64;

  final _incoming = <String, _IncomingPouchFile>{};
  final _stored = <String, _StoredPouchFile>{};

  static String _key(String peerId, String fileId) => '$peerId\n$fileId';

  static bool _validFileId(String fileId) {
    if (fileId.length < 8 || fileId.length > 64) return false;
    return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(fileId);
  }

  String? begin({
    required String peerId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required String semanticType,
    required int size,
    required String ownerId,
    required String channelId,
  }) {
    if (!_validFileId(fileId)) return '附件编号无效';
    if (size <= 0 || size > AttachmentData.maxSizeBytes) return '附件大小无效';
    if (ownerId.isEmpty || channelId.isEmpty) return '附件没有落点';
    final key = _key(peerId, fileId);
    if (_incoming.containsKey(key)) return '附件编号重复';
    if (_incoming.length >= _maxInflight) return '同时上传的附件太多';
    _incoming[key] = _IncomingPouchFile(
      fileName: fileName,
      mimeType: mimeType,
      semanticType: semanticType,
      size: size,
      ownerId: ownerId,
      channelId: channelId,
    );
    return null;
  }

  String? addChunk({
    required String peerId,
    required String fileId,
    required int index,
    required Uint8List bytes,
  }) {
    final incoming = _incoming[_key(peerId, fileId)];
    if (incoming == null) return '未知的附件';
    if (index < 0 || index > 512) {
      _incoming.remove(_key(peerId, fileId));
      return '附件分片序号无效';
    }
    incoming.chunks[index] = bytes;
    var total = 0;
    for (final part in incoming.chunks.values) {
      total += part.length;
      if (total > AttachmentData.maxSizeBytes) {
        _incoming.remove(_key(peerId, fileId));
        return '附件超过大小上限';
      }
    }
    return null;
  }

  void drop(String peerId, String fileId) {
    _incoming.remove(_key(peerId, fileId));
  }

  Future<({String? error, String? storeUri})> finish({
    required String peerId,
    required String fileId,
    required int chunkCount,
    required PouchBytesStore store,
  }) async {
    final key = _key(peerId, fileId);
    final incoming = _incoming.remove(key);
    if (incoming == null) return (error: '未知的附件', storeUri: null);
    if (chunkCount <= 0 || incoming.chunks.length != chunkCount) {
      return (error: '分片数量不一致', storeUri: null);
    }
    final ordered = <int>[];
    for (var i = 0; i < chunkCount; i++) {
      final part = incoming.chunks[i];
      if (part == null) return (error: '缺少分片 $i', storeUri: null);
      ordered.addAll(part);
    }
    if (ordered.length != incoming.size ||
        ordered.length > AttachmentData.maxSizeBytes) {
      return (error: '附件大小与声明不符', storeUri: null);
    }
    try {
      final bytes = Uint8List.fromList(ordered);
      final storeUri = await store(
        bytes,
        ownerId: incoming.ownerId,
        channelId: incoming.channelId,
      );
      if (_stored.length >= _maxStored) {
        _stored.remove(_stored.keys.first);
      }
      _stored[key] = _StoredPouchFile(
        storeUri: storeUri,
        fileName: incoming.fileName,
        mimeType: incoming.mimeType,
        semanticType: incoming.semanticType,
      );
      return (error: null, storeUri: storeUri);
    } catch (e) {
      return (error: '$e', storeUri: null);
    }
  }

  /// 按本连接上传过的编号取回字节。领取后不能再用同一个编号。
  Future<List<AttachmentData>?> take({
    required String peerId,
    required dynamic raw,
    required Future<Uint8List?> Function(String storeUri) read,
  }) async {
    final refs = AttachmentData.peerRefListFromJson(raw);
    if (refs == null) return null;
    final found =
        <({Map<String, dynamic> ref, _StoredPouchFile stored, String key})>[];
    for (final ref in refs) {
      final fileId = ref['file_id'] as String;
      final key = _key(peerId, fileId);
      final stored = _stored[key];
      if (stored == null) throw StateError('未知的附件: $fileId');
      found.add((ref: ref, stored: stored, key: key));
    }
    for (final item in found) {
      _stored.remove(item.key);
    }
    final out = <AttachmentData>[];
    for (final item in found) {
      final bytes = await read(item.stored.storeUri);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('附件不在主机上: ${item.ref['file_id']}');
      }
      final extra = <String, dynamic>{'store_uri': item.stored.storeUri};
      final hint =
          MessageImplicitPrompt.renderStoreReadHint([item.stored.storeUri]);
      MessageImplicitPrompt.putInMetadata(
        extra,
        hint: hint,
        uris: [item.stored.storeUri],
      );
      final clientExtra = item.ref['extra'];
      if (clientExtra is Map) {
        for (final entry in clientExtra.entries) {
          final key = entry.key.toString();
          if (key == 'store_uri' ||
              key == MessageImplicitPrompt.metaKey ||
              key == MessageImplicitPrompt.urisMetaKey) {
            continue;
          }
          extra[key] = entry.value;
        }
      }
      out.add(AttachmentData(
        fileName: item.ref['file_name'] as String? ?? item.stored.fileName,
        mimeType: item.ref['mime_type'] as String? ?? item.stored.mimeType,
        sizeBytes: bytes.length,
        bytes: bytes,
        semanticType: item.ref['type'] as String? ?? item.stored.semanticType,
        fileId: item.ref['file_id'] as String?,
        extraMetadata: extra,
      ));
    }
    return out;
  }
}

class _IncomingPouchFile {
  _IncomingPouchFile({
    required this.fileName,
    required this.mimeType,
    required this.semanticType,
    required this.size,
    required this.ownerId,
    required this.channelId,
  });

  final String fileName;
  final String mimeType;
  final String semanticType;
  final int size;
  final String ownerId;
  final String channelId;
  final chunks = <int, Uint8List>{};
}

class _StoredPouchFile {
  const _StoredPouchFile({
    required this.storeUri,
    required this.fileName,
    required this.mimeType,
    required this.semanticType,
  });

  final String storeUri;
  final String fileName;
  final String mimeType;
  final String semanticType;
}

/// 主机收到分片后写入 runtime，再等回合帧来领取。
class PouchAttachmentHost {
  PouchAttachmentHost._();

  static Future<void> onBegin(String peerId, Map<String, dynamic> data) async {
    final fileId = data['file_id'] as String? ?? '';
    Future<void> ack(bool ok, String stage, {String? error}) {
      return PeerConnectionManager.instance.sendControl(peerId, {
        'type': PouchAttachment.ackType,
        'file_id': fileId,
        'ok': ok,
        'stage': stage,
        if (error != null) 'error': error,
      });
    }

    try {
      final role = await PouchRoleStore(
        await StoreService.instance.storeRoot(),
      ).load();
      if (!role.isHost) {
        await ack(false, 'begin', error: '这台设备不是储物袋主机');
        return;
      }
      final placement = data['placement'] as String? ?? 'dm';
      final agentId = data['agent_id'] as String? ?? '';
      final channelId = data['channel_id'] as String? ?? '';
      if (placement == 'group' && channelId.trim().isEmpty) {
        await ack(false, 'begin', error: '群附件没有会话');
        return;
      }
      if (placement != 'group' &&
          agentId.trim().isEmpty &&
          channelId.trim().isEmpty) {
        await ack(false, 'begin', error: '附件没有会话');
        return;
      }
      String? parentGroupId;
      if (placement == 'group') {
        try {
          final channel =
              await LocalDatabaseService().getChannelById(channelId);
          final family = channel?.groupFamilyId.trim() ?? '';
          if (family.isNotEmpty) parentGroupId = family;
        } catch (_) {}
      }
      final target = PouchAttachmentPlacement.resolve(
        placement: placement,
        agentId: agentId,
        channelId: channelId,
        parentGroupId: parentGroupId,
      );
      final error = PouchAttachmentDesk.instance.begin(
        peerId: peerId,
        fileId: fileId,
        fileName: data['file_name'] as String? ?? 'file',
        mimeType: data['mime_type'] as String? ?? 'application/octet-stream',
        semanticType: data['file_type'] as String? ?? 'file',
        size: (data['size'] as num?)?.toInt() ?? 0,
        ownerId: target.ownerId,
        channelId: target.channelId,
      );
      if (error != null) {
        await ack(false, 'begin', error: error);
        return;
      }
      await ack(true, 'begin');
    } catch (e) {
      PouchAttachmentDesk.instance.drop(peerId, fileId);
      await ack(false, 'begin', error: '$e');
    }
  }

  static void onChunk(String peerId, Map<String, dynamic> data) {
    final fileId = data['file_id'] as String?;
    final index = (data['index'] as num?)?.toInt();
    final encoded = data['data'] as String?;
    if (fileId == null || index == null || encoded == null) return;
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (e) {
      PouchAttachmentDesk.instance.drop(peerId, fileId);
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': PouchAttachment.ackType,
        'file_id': fileId,
        'ok': false,
        'stage': 'end',
        'error': '分片无法解码',
      }));
      return;
    }
    final error = PouchAttachmentDesk.instance.addChunk(
      peerId: peerId,
      fileId: fileId,
      index: index,
      bytes: bytes,
    );
    if (error == null || error == '未知的附件') return;
    unawaited(PeerConnectionManager.instance.sendControl(peerId, {
      'type': PouchAttachment.ackType,
      'file_id': fileId,
      'ok': false,
      'stage': 'end',
      'error': error,
    }));
  }

  static Future<void> onEnd(String peerId, Map<String, dynamic> data) async {
    final fileId = data['file_id'] as String? ?? '';
    final done = await PouchAttachmentDesk.instance.finish(
      peerId: peerId,
      fileId: fileId,
      chunkCount: (data['chunk_count'] as num?)?.toInt() ?? 0,
      store: AttachmentStoreWriter.storeBytes,
    );
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': PouchAttachment.ackType,
      'file_id': fileId,
      'ok': done.error == null,
      'stage': 'end',
      if (done.storeUri != null) 'store_uri': done.storeUri,
      if (done.error != null) 'error': done.error,
    });
  }
}

/// 客户端推送。 [send] 在测试里替换，正式路径走配对连接。
class PouchAttachmentClient {
  PouchAttachmentClient({required this.send});

  final Future<bool> Function(String peerId, Map<String, dynamic> frame) send;
  final _uuid = const Uuid();
  final _pending = <String, _PendingPouchFile>{};

  void onAck(Map<String, dynamic> data) {
    final fileId = data['file_id'] as String?;
    if (fileId == null) return;
    final pending = _pending[fileId];
    if (pending == null) return;
    final ok = data['ok'] != false;
    final stage = data['stage'] as String? ?? 'end';
    final error = data['error'] as String? ?? '附件被主机拒绝';
    if (stage == 'begin') {
      if (ok) {
        if (!pending.begin.isCompleted) pending.begin.complete();
      } else {
        _fail(fileId, pending, error);
      }
      return;
    }
    if (ok) {
      if (!pending.begin.isCompleted) pending.begin.complete();
      if (!pending.end.isCompleted) pending.end.complete();
    } else {
      _fail(fileId, pending, error);
    }
  }

  void _fail(String fileId, _PendingPouchFile pending, String error) {
    _pending.remove(fileId);
    final wrapped = StateError(error);
    if (!pending.begin.isCompleted) {
      pending.begin.completeError(wrapped);
      pending.begin.future.ignore();
    }
    if (!pending.end.isCompleted) {
      pending.end.completeError(wrapped);
      pending.end.future.ignore();
    }
  }

  void _cancel(String fileId) {
    _pending.remove(fileId);
  }

  Future<String> push({
    required String peerId,
    required AttachmentData attachment,
    required String agentId,
    required String channelId,
    required String placement,
  }) async {
    final fileId = _uuid.v4().replaceAll('-', '').substring(0, 12);
    final pending = _PendingPouchFile();
    _pending[fileId] = pending;

    final began = await send(peerId, {
      'type': PouchAttachment.beginType,
      'file_id': fileId,
      'file_name': attachment.fileName,
      'mime_type': attachment.mimeType,
      'file_type': attachment.semanticType,
      'size': attachment.sizeBytes,
      'agent_id': agentId,
      'channel_id': channelId,
      'placement': placement,
    });
    if (!began) {
      _cancel(fileId);
      throw StateError('无法把附件交给储物袋主机');
    }
    try {
      await pending.begin.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      _cancel(fileId);
      throw StateError('主机未响应附件: ${attachment.fileName}');
    }

    final bytes = attachment.bytes;
    const chunkSize = AttachmentData.peerChunkBytes;
    var index = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end =
          offset + chunkSize < bytes.length ? offset + chunkSize : bytes.length;
      final sent = await send(peerId, {
        'type': PouchAttachment.chunkType,
        'file_id': fileId,
        'index': index,
        'data': base64Encode(bytes.sublist(offset, end)),
      });
      if (!sent) {
        _cancel(fileId);
        throw StateError('附件分片没有送到主机');
      }
      index++;
    }

    final ended = await send(peerId, {
      'type': PouchAttachment.endType,
      'file_id': fileId,
      'chunk_count': index,
    });
    if (!ended) {
      _cancel(fileId);
      throw StateError('附件结束帧没有送到主机');
    }
    try {
      await pending.end.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      _cancel(fileId);
      throw StateError('主机保存附件超时: ${attachment.fileName}');
    }
    _pending.remove(fileId);
    return fileId;
  }
}

class _PendingPouchFile {
  final begin = Completer<void>();
  final end = Completer<void>();
}
