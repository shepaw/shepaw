import 'pouch_scope.dart';

/// 群工作区内容在 v3 袋子里的落点。
///
/// 切换方案把
/// - `workspaces/<gid>/shared/<rel>` 映射到 `group:<gid>:shared/<rel>`，
/// - `workspaces/<gid>/members/<aid>/<rel>` 映射到
///   `group:<gid>:member:<aid>/<rel>`（见 CLI 仓库
///   `docs/design/2026-10-21-pouch-v3-b-single-pouch-cutover.md` 4.3 / 5 节）。
///
/// 群共享文件（`shared/files/<rel>`）本来就是同一条映射，所以共享文件、群记忆、
/// 交接包、任务状态在袋子里落在同一个 scope 下。
///
/// 群元数据不在这里映射：成员/角色以 hub 的 `system/groups.json` 为准；
/// 注册表缺失时 App 把兜底成员表写到群根 `group:<gid>/workspace.json`
/// （由 [GroupWorkspaceService] 直接读写，不经过本映射）。
class GroupWorkspaceScopes {
  GroupWorkspaceScopes._();

  /// `workspaces/<gid>/<tail>` → 袋子里的 scope + 路径；不在映射内返回 null。
  static ({PouchScope scope, String path})? map(String workspacePath) {
    final parts = workspacePath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    final groupId = parts[0];
    if (!isValidPouchScopeId(groupId)) return null;
    if (parts[1] == 'shared') {
      final rel = parts.sublist(2).join('/');
      if (rel.isEmpty) return null;
      return (scope: PouchScope.groupShared(groupId), path: rel);
    }
    // members/<aid>/<rel>：成员私有区，写入方是 agent CLI。
    if (parts[1] == 'members' && parts.length >= 4) {
      final agentId = parts[2];
      if (!isValidPouchScopeId(agentId)) return null;
      final rel = parts.sublist(3).join('/');
      if (rel.isEmpty) return null;
      return (scope: PouchScope.groupMember(groupId, agentId), path: rel);
    }
    return null;
  }

  /// 群共享面的 scope；群 id 不合法时返回 null。
  static PouchScope? sharedScope(String groupId) {
    if (!isValidPouchScopeId(groupId)) return null;
    return PouchScope.groupShared(groupId);
  }
}
