import 'dart:convert';

import '../../models/message.dart';
import '../messaging/chat_history_content.dart';

/// 把同一回合里已经审过的 CLI 工具收进一条气泡，当作审计。
///
/// 待审的那一张仍挂在 `action_confirmation` 上。一旦选出允许 / 拒绝 / 过期，
/// 就从交互卡挪进 [metadataKey]，气泡只留下工具名和参数。
class CliAuditFold {
  CliAuditFold._();

  static const metadataKey = 'cli_audit';
  static const hostFlag = 'cli_audit_host';

  /// 审计气泡 id 前缀。不要用 `peer_approval_` / `group_peer_approval_`，
  /// 那两个会被流式对账当成占位折叠掉。
  static const messageIdPrefix = 'cli_audit_';

  static bool isHost(Map<String, dynamic>? metadata) =>
      metadata?[hostFlag] == true;

  static List<Map<String, dynamic>> read(Map<String, dynamic>? metadata) {
    final raw = metadata?[metadataKey];
    if (raw is! List) return [];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is Map) {
        out.add(Map<String, dynamic>.from(item));
      }
    }
    return out;
  }

  /// `allow` / `deny` / `expired`。还没选时返回空串。
  static String decisionOf(Map<String, dynamic> actionConfirmation) {
    final id =
        (actionConfirmation['selected_action_id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return '';
    if (id == 'allow' || id == 'allow_session') return 'allow';
    if (id == 'deny') return 'deny';
    if (id == 'expired') return 'expired';
    return id;
  }

  static Map<String, dynamic> entryFrom(
    Map<String, dynamic> actionConfirmation,
    String decision,
  ) {
    final flags = actionConfirmation['flags'];
    return {
      'confirmation_id': actionConfirmation['confirmation_id'] ?? '',
      'tool_name': actionConfirmation['tool_name'] ?? '',
      'params': flags is Map
          ? Map<String, dynamic>.from(flags)
          : <String, dynamic>{},
      'decision': decision,
    };
  }

  /// 把已裁决的 `action_confirmation` 收进审计列表，并拆掉交互卡。
  ///
  /// 未裁决时原样返回。不会把普通回复标成审计宿主，避免下一张确认贴进正文。
  static Map<String, dynamic> foldDecided(Map<String, dynamic>? metadata) {
    final meta = Map<String, dynamic>.from(metadata ?? {});
    final ac = meta['action_confirmation'];
    if (ac is! Map) return meta;
    final action = Map<String, dynamic>.from(ac);
    final decision = decisionOf(action);
    if (decision.isEmpty) return meta;

    final entry = entryFrom(action, decision);
    final list = read(meta);
    final id = entry['confirmation_id'];
    final already = id is String &&
        id.isNotEmpty &&
        list.any((e) => e['confirmation_id'] == id);
    if (!already) list.add(entry);
    meta[metadataKey] = list;
    meta.remove('action_confirmation');
    meta.remove('action_confirmation_responded');
    if (meta[hostFlag] == true) {
      meta[ChatHistoryContent.historyExcludeMetaKey] = true;
    }
    return meta;
  }

  /// 把下一张待审卡挂到同一条审计气泡上。
  ///
  /// 当前卡如果已经裁决，先折进去再挂新的。当前卡还在等点击时返回 null，
  /// 调用方应另起一条，不能把没答的卡盖掉。同一张卡重复挂载则原样返回。
  static Map<String, dynamic>? attachPending({
    required Map<String, dynamic>? metadata,
    required Map<String, dynamic> actionData,
  }) {
    final meta = Map<String, dynamic>.from(metadata ?? {});
    final ac = meta['action_confirmation'];
    if (ac is Map) {
      final current = Map<String, dynamic>.from(ac);
      if (current['confirmation_id'] == actionData['confirmation_id']) {
        return meta;
      }
      if (current['selected_action_id'] == null) return null;
      final folded = foldDecided(meta);
      meta
        ..clear()
        ..addAll(folded);
    }
    meta['action_confirmation'] = Map<String, dynamic>.from(actionData);
    meta[hostFlag] = true;
    meta[ChatHistoryContent.historyExcludeMetaKey] = true;
    return meta;
  }

  /// 本回合（最近一条用户消息之后）里、该 agent 最新的审计气泡。
  static Message? findHost(List<Message> messages, String agentId) {
    for (final message in messages.reversed) {
      if (message.from.isUser) return null;
      if (message.from.id != agentId) continue;
      if (isHost(message.metadata)) return message;
    }
    return null;
  }

  static String messageIdFor(String agentId, int nowMs) =>
      '$messageIdPrefix${agentId}_$nowMs';

  /// 参数按 `key: value` 逐行展示。过长的值截断，避免一条审计把气泡撑满。
  static String formatParams(
    Map<String, dynamic> params, {
    int maxValueChars = 400,
    int maxEntries = 12,
  }) {
    if (params.isEmpty) return '';
    final lines = <String>[];
    var shown = 0;
    for (final entry in params.entries) {
      if (shown >= maxEntries) {
        lines.add('…');
        break;
      }
      var value = _stringify(entry.value);
      if (value.length > maxValueChars) {
        value = '${value.substring(0, maxValueChars)}…';
      }
      lines.add('${entry.key}: $value');
      shown++;
    }
    return lines.join('\n');
  }

  static String _stringify(Object? value) {
    if (value == null) return 'null';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }
}
