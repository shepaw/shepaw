/// 流程名的规矩。镜像主机 `crates/api/src/flow/store.rs::check_name`：
/// 名字最终要拼进储物袋的 scope，所以字符集和保留字都得对齐。
class FlowNameRules {
  FlowNameRules._();

  /// 储物袋自己占用的几个名字。
  static const reserved = ['shared', 'session', 'task', 'member'];

  static final RegExp _allowed = RegExp(r'^[A-Za-z0-9_.-]+$');

  /// 名字的问题；没问题返回 null。
  static FlowNameProblem? check(String name) {
    if (name.trim().isEmpty) return FlowNameProblem.empty;
    if (reserved.contains(name)) return FlowNameProblem.reserved;
    if (!_allowed.hasMatch(name)) return FlowNameProblem.invalid;
    return null;
  }
}

enum FlowNameProblem { empty, reserved, invalid }

/// 新建空白流程的骨架。
///
/// 空 `steps` 是合法的（`validate` 只检查容器自己的 `steps` 不能为空，不管根
/// 层），所以主机肯收；之后每一步都靠结构操作加进去。
class FlowBlankFlow {
  FlowBlankFlow._();

  static String skeleton(String name) => 'flow: $name\nversion: 1\nsteps: []\n';
}
