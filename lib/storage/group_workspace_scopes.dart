import 'pouch_scope.dart';

/// 群工作区内容在 v3 袋子里的落点。
///
/// 切换方案把 `workspaces/<gid>/shared/<rel>` 映射到
/// `group:<gid>:shared/<rel>`（见 CLI 仓库
/// `docs/design/2026-10-21-pouch-v3-b-single-pouch-cutover.md` 4.3 / 5 节）。
/// 群共享文件（`shared/files/<rel>`）本来就是这条映射，所以共享文件、群记忆、
/// 交接包、任务状态在袋子里落在同一个 scope 下，ACL 也只需这一条。
///
/// **暂不映射**（App 侧继续写 v2）：
/// - `group-workspace.json`：成员/角色/归属设备，v3 由 hub 的
///   `system/groups.json` + `group:<gid>/meta.json` 承担，App 何时停写要等
///   hub 先切完；
/// - `members/<aid>/…`：成员私有区，写入方是 agent CLI（不是手机 App）。
class GroupWorkspaceScopes {
  GroupWorkspaceScopes._();

  /// `workspaces/<gid>/<tail>` → 袋子里的 scope + 路径；不在映射内返回 null。
  static ({PouchScope scope, String path})? map(String workspacePath) {
    final parts = workspacePath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3 || parts[1] != 'shared') return null;
    final groupId = parts[0];
    if (!isValidPouchScopeId(groupId)) return null;
    final rel = parts.sublist(2).join('/');
    if (rel.isEmpty) return null;
    return (scope: PouchScope.groupShared(groupId), path: rel);
  }

  /// 群共享面的 scope；群 id 不合法时返回 null。
  static PouchScope? sharedScope(String groupId) {
    if (!isValidPouchScopeId(groupId)) return null;
    return PouchScope.groupShared(groupId);
  }
}
