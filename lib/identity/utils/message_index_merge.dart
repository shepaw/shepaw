/// 将 App 设备 message index 与本地缓存正文合并为频道消息列表行。
List<Map<String, dynamic>> mergeChannelMessagesWithIndex({
  required List<Map<String, dynamic>> indexRows,
  required List<Map<String, dynamic>> messageRows,
}) {
  final byId = <String, Map<String, dynamic>>{
    for (final row in messageRows)
      if (row['id'] is String) row['id'] as String: row,
  };

  final merged = <Map<String, dynamic>>[];
  for (final idx in indexRows) {
    final id = idx['message_id'] as String?;
    if (id == null || id.isEmpty) continue;
    final cached = byId[id];
    if (cached != null) {
      final content = cached['content'] as String? ?? '';
      if (content.isEmpty) {
        merged.add({
          ...cached,
          'content': idx['preview'] as String? ?? '',
        });
      } else {
        merged.add(cached);
      }
    } else {
      merged.add(syntheticMessageRowFromIndex(idx));
    }
  }
  return merged;
}

Map<String, dynamic> syntheticMessageRowFromIndex(Map<String, dynamic> idx) {
  final wallTime = idx['wall_time'] as int? ?? 0;
  final createdAt = DateTime.fromMillisecondsSinceEpoch(wallTime).toIso8601String();
  final hasAttachment = (idx['has_attachment'] as int? ?? 0) == 1;
  return {
    'id': idx['message_id'],
    'channel_id': idx['channel_id'],
    'sender_id': 'sync',
    'sender_type': 'user',
    'sender_name': idx['sender_name'] as String? ?? '',
    'message_type': hasAttachment ? 'file' : 'text',
    'content': idx['preview'] as String? ?? '',
    'created_at': createdAt,
    'updated_at': createdAt,
    'is_read': 0,
    'metadata': null,
  };
}
