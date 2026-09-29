import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// 一条聊天记录在储物袋里的形状。同一条消息多次写入时，后写的覆盖先写的。
class PouchChatRecord {
  const PouchChatRecord({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.senderType,
    required this.senderName,
    required this.content,
    required this.messageType,
    required this.createdAt,
    this.metadata,
    this.replyToId,
    this.isRead = 0,
    this.deleted = false,
  });

  final String id;
  final String channelId;
  final String senderId;
  final String senderType;
  final String senderName;
  final String content;
  final String messageType;
  final String createdAt;
  final Map<String, dynamic>? metadata;
  final String? replyToId;
  final int isRead;
  final bool deleted;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'channel_id': channelId,
        'sender_id': senderId,
        'sender_type': senderType,
        'sender_name': senderName,
        'content': content,
        'message_type': messageType,
        'created_at': createdAt,
        'is_read': isRead,
        if (metadata != null) 'metadata': metadata,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (deleted) 'deleted': true,
      };

  static PouchChatRecord? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final channelId = (json['channel_id'] as String?)?.trim() ?? '';
    if (id.isEmpty || channelId.isEmpty) return null;
    final meta = json['metadata'];
    return PouchChatRecord(
      id: id,
      channelId: channelId,
      senderId: json['sender_id'] as String? ?? '',
      senderType: json['sender_type'] as String? ?? 'user',
      senderName: json['sender_name'] as String? ?? '',
      content: json['content'] as String? ?? '',
      messageType: json['message_type'] as String? ?? 'text',
      createdAt: json['created_at'] as String? ?? '',
      metadata: meta is Map ? meta.cast<String, dynamic>() : null,
      replyToId: json['reply_to_id'] as String?,
      isRead: (json['is_read'] as num?)?.toInt() ?? 0,
      deleted: json['deleted'] == true,
    );
  }

  static PouchChatRecord fromSqliteRow(Map<String, dynamic> row) {
    Map<String, dynamic>? metadata;
    final raw = row['metadata'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) metadata = decoded.cast<String, dynamic>();
    } else if (raw is Map) {
      metadata = raw.cast<String, dynamic>();
    }
    return PouchChatRecord(
      id: row['id'] as String? ?? '',
      channelId: row['channel_id'] as String? ?? '',
      senderId: row['sender_id'] as String? ?? '',
      senderType: row['sender_type'] as String? ?? 'user',
      senderName: row['sender_name'] as String? ?? '',
      content: row['content'] as String? ?? '',
      messageType: row['message_type'] as String? ?? 'text',
      createdAt: row['created_at'] as String? ?? '',
      metadata: metadata,
      replyToId: row['reply_to_id'] as String?,
      isRead: (row['is_read'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `.system/chat/<channel>.jsonl`。界面仍读 SQLite，这里是随袋子迁移的那份。
class PouchChatLog {
  PouchChatLog(this.root);

  final Directory root;

  /// 启动后绑定。未绑定时写入方直接跳过，单测里的数据库不会去碰磁盘。
  static PouchChatLog? bound;

  static void bind(PouchChatLog log) {
    bound = log;
  }

  final _lastId = <String, String>{};
  final _tails = <String, Future<void>>{};

  /// 同一频道的追加串行，避免流式更新和删除交错写坏最后一行。
  Future<void> _enqueue(String channelId, Future<void> Function() action) {
    final prev = _tails[channelId] ?? Future<void>.value();
    final done = prev.catchError((Object _) {}).then((_) => action());
    _tails[channelId] = done;
    return done;
  }

  File fileFor(String channelId) {
    final digest = crypto.sha256.convert(utf8.encode(channelId)).toString();
    final safe = channelId
        .replaceAll(RegExp(r'[/\\]+'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'[^\w.\-@+]'), '_');
    final leaf = safe.isEmpty ? 'channel' : safe;
    final name = leaf.length > 80 ? leaf.substring(0, 80) : leaf;
    return File(p.join(root.path, '.system', 'chat', '$name-${digest.substring(0, 12)}.jsonl'));
  }

  /// 追加一条。若文件最后一条就是同一个 id（流式更新），改写这一行而不是再追加。
  Future<void> upsert(PouchChatRecord record) {
    if (record.id.isEmpty || record.channelId.isEmpty) return Future.value();
    return _enqueue(record.channelId, () => _upsertNow(record));
  }

  Future<void> _upsertNow(PouchChatRecord record) async {
    final file = fileFor(record.channelId);
    await file.parent.create(recursive: true);
    final line = '${jsonEncode(record.toJson())}\n';
    if (_lastId[record.channelId] == record.id && await file.exists()) {
      await _replaceLastLine(file, line);
      return;
    }
    await file.writeAsString(line, mode: FileMode.append);
    _lastId[record.channelId] = record.id;
  }

  Future<void> upsertAll(List<PouchChatRecord> records) async {
    for (final record in records) {
      await upsert(record);
    }
  }

  Future<void> tombstone({
    required String channelId,
    required String messageId,
  }) async {
    await upsert(PouchChatRecord(
      id: messageId,
      channelId: channelId,
      senderId: '',
      senderType: 'system',
      senderName: '',
      content: '',
      messageType: 'system',
      createdAt: '',
      deleted: true,
    ));
  }

  Future<void> deleteChannel(String channelId) {
    return _enqueue(channelId, () async {
      final file = fileFor(channelId);
      _lastId.remove(channelId);
      if (await file.exists()) await file.delete();
    });
  }

  /// 折叠修订后的当前消息，按写入顺序。已删除的不返回。
  Future<List<PouchChatRecord>> readChannel(String channelId) async {
    final file = fileFor(channelId);
    if (!await file.exists()) return const [];
    final byId = <String, PouchChatRecord>{};
    final order = <String>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) continue;
      final record = PouchChatRecord.fromJson(decoded.cast<String, dynamic>());
      if (record == null) continue;
      if (!byId.containsKey(record.id)) order.add(record.id);
      byId[record.id] = record;
    }
    return [
      for (final id in order)
        if (byId[id]!.deleted == false) byId[id]!,
    ];
  }

  Future<void> _replaceLastLine(File file, String line) async {
    final raf = await file.open(mode: FileMode.append);
    try {
      final length = await raf.length();
      if (length == 0) {
        await raf.writeFrom(utf8.encode(line));
        return;
      }
      var pos = length;
      // 最后一行以换行结束。往前找到上一条的换行，从那里覆盖。
      while (pos > 0) {
        pos -= 1;
        await raf.setPosition(pos);
        final byte = Uint8List(1);
        await raf.readInto(byte);
        if (byte[0] == 10 && pos < length - 1) {
          pos += 1;
          break;
        }
        if (pos == 0) break;
      }
      await raf.setPosition(pos);
      await raf.truncate(pos);
      await raf.writeFrom(utf8.encode(line));
    } finally {
      await raf.close();
    }
  }
}
