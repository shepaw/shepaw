// 储物袋目录名 → 可读标签（Agent / 群名称与头像）解析。

import '../services/local_database_service.dart';
import 'store_protocol.dart';

/// 目录名为 agent/群 id 的分区；其余分区（files/public/backups 等）不做解析，
/// 避免把用户自建目录误解析成 Agent/群。
const _labelResolvableSpaces = <String>{
  StoreSpace.workspaces,
  StoreSpace.runtime,
  StoreSpace.cognition,
  StoreSpace.memory, // legacy：cognition 别名，同样按 <agentId> 布局
  StoreSpace.artifacts, // legacy：owner 目录布局，命中不了则原样
};

/// 储物袋中 agent/群 id 目录的可读标签。
class StorageFolderLabel {
  const StorageFolderLabel({
    required this.label,
    required this.avatar,
    required this.isGroup,
    required this.resolved,
  });

  /// 未解析时的原样标签（label = 原始目录名，显示文件夹图标）。
  factory StorageFolderLabel.unresolved(String name) => StorageFolderLabel(
        label: name,
        avatar: '',
        isGroup: false,
        resolved: false,
      );

  /// 展示名；未解析时为原始目录名。
  final String label;

  /// 头像（emoji/URL/asset）；空串 = 无自定义头像（UI 用默认图标兜底）。
  final String avatar;

  /// 是否为群目录（决定无头像时的默认图标）。
  final bool isGroup;

  /// 是否已解析为真实 Agent/群。
  final bool resolved;
}

/// 把储物袋目录名解析为可读标签。
///
/// - 群：先按原始名查 channel（runtime owner 目录名 == channel id），未命中且
///   带 `group_` 前缀时再剥一层（workspaces 根为 `group_group_<uuid>`）。命中且
///   [Channel.isGroup] 才标为群，避免把 DM 会话误标成群。
/// - Agent：本地与远端共用 `agents` 表，[LocalDatabaseService.getAgentById] 即可。
/// - 解析失败一律返回 [StorageFolderLabel.unresolved]，不抛异常。
Future<StorageFolderLabel> resolveStorageFolderLabel(
  String space,
  String name, {
  LocalDatabaseService? db,
}) async {
  if (name.isEmpty || !_labelResolvableSpaces.contains(space)) {
    return StorageFolderLabel.unresolved(name);
  }
  final dao = db ?? LocalDatabaseService();

  try {
    final ch1 = await dao.getChannelById(name);
    if (ch1 != null && ch1.isGroup) {
      return StorageFolderLabel(
        label: ch1.name,
        avatar: ch1.avatar ?? '',
        isGroup: true,
        resolved: true,
      );
    }
    if (name.startsWith('group_')) {
      final stripped = name.substring('group_'.length);
      if (stripped.isNotEmpty) {
        final ch2 = await dao.getChannelById(stripped);
        if (ch2 != null && ch2.isGroup) {
          return StorageFolderLabel(
            label: ch2.name,
            avatar: ch2.avatar ?? '',
            isGroup: true,
            resolved: true,
          );
        }
      }
    }
  } catch (_) {
    // DB 异常不影响目录浏览，回落。
  }

  try {
    final agent = await dao.getAgentById(name);
    if (agent != null) {
      return StorageFolderLabel(
        label: agent.name,
        avatar: agent.avatar,
        isGroup: false,
        resolved: true,
      );
    }
  } catch (_) {}

  return StorageFolderLabel.unresolved(name);
}
