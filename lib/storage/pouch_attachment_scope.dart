/// 附件/文件落点跟着「这一端选过的会话」走（G4 / B 4.3）。
///
/// 落点来自 hub 的 `v3/layout.rs`：
/// - 群消息附件：`group:<gid>:session:<sid>/attachments/<message_id>/<file>`；
/// - agent 会话附件：`agent:<aid>:session:<sid>/attachments/<file>`；
/// - 没有会话：`agent:<aid>/files/attachments/<file>`。
///
/// 会话 id 只认 [GroupSessionSelection] 里这一端选过的那个；没选过就返回
/// null，让调用方走「没有会话」的落点——不猜主机的 current_session。
library;

import '../peer/services/hub_group_sessions.dart';
import 'pouch_scope.dart';
import 'store_protocol.dart';

class PouchAttachmentScopes {
  PouchAttachmentScopes._();

  /// 群这一端选过的会话 scope；没选过返回 null。
  static PouchScope? groupSession(String groupId) {
    final sessionId = GroupSessionSelection.of(groupId)?.trim() ?? '';
    if (groupId.trim().isEmpty || sessionId.isEmpty) return null;
    return PouchScope.groupSession(groupId.trim(), sessionId);
  }

  /// agent 的会话 scope；没有会话 id 返回 null。
  static PouchScope? agentSession(String agentId, String sessionId) {
    final aid = agentId.trim();
    final sid = sessionId.trim();
    if (aid.isEmpty || sid.isEmpty) return null;
    return PouchScope.agentSession(aid, sid);
  }

  /// 会话里的附件路径。
  static String sessionAttachmentPath(String file) => 'attachments/$file';

  /// 群消息附件路径（按消息再分一层）。
  static String groupMessageAttachmentPath(String messageId, String file) =>
      'attachments/$messageId/$file';

  /// 没有会话时的 agent 附件路径。
  static String agentAttachmentPath(String file) => 'files/attachments/$file';

  /// 附件地址；[scope] 已经由上面几个方法算好。
  static String uri({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) =>
      PouchV2Uri(pouchId: pouchId, scope: scope.id, path: path).format();

  /// 群附件地址：用这一端选过的会话；没选过返回 null。
  static String? groupAttachmentUri({
    required String groupId,
    required String pouchId,
    required String file,
    String? messageId,
  }) {
    final scope = groupSession(groupId);
    if (scope == null) return null;
    final path = messageId == null || messageId.isEmpty
        ? sessionAttachmentPath(file)
        : groupMessageAttachmentPath(messageId, file);
    return uri(pouchId: pouchId, scope: scope, path: path);
  }

  /// agent 会话附件地址；没有会话时落到 `agent:<aid>/files/attachments`。
  static String agentAttachmentUri({
    required String agentId,
    required String pouchId,
    required String file,
    String? sessionId,
  }) {
    final scope = agentSession(agentId, sessionId ?? '');
    if (scope == null) {
      return uri(
        pouchId: pouchId,
        scope: PouchScope.agent(agentId),
        path: agentAttachmentPath(file),
      );
    }
    return uri(
      pouchId: pouchId,
      scope: scope,
      path: sessionAttachmentPath(file),
    );
  }
}
