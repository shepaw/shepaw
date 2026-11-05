import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

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

/// 新建 / 另存为之前，先在库里查一次重名。
///
/// 老主机不认 `create_only`（serde 忽略未知字段），同名新建会静默变成给已有
/// 流程追加一版，把那份定义覆盖掉。客户端这道关只能减少撞名，**兜不住两次请求
/// 之间的竞态**：新主机靠 `create_only` 原子保证，老主机没有这个能力，混用旧主机
/// 时两次同时新建仍可能互相覆盖，只能靠升级主机解决。
/// `flow_list_req` 是两端都有的老帧，不需要能力探测。
enum FlowNameAvailability {
  /// 名单里没有这个名字，可以写。
  free,

  /// 名单里已经有了，拦下。
  taken,

  /// 主机根本没应答（超时 / 对端不可达）。保存多半也会失败，不写。
  unavailable,

  /// 主机回了 `flow_list_resp`，但没给出可用名单（例如库里有一个坏掉的
  /// meta.json 让 list 整体失败）。这不是「主机没回应」，也不该把写入挡死 ——
  /// 新主机的 `create_only` 是原子的，照常写即可。
  unverified,
}

class FlowNameGuard {
  FlowNameGuard._();

  static Future<FlowNameAvailability> check(
    HubFlow client,
    String peerId,
    String name, {
    String scope = '',
  }) async {
    final response = await client.listRaw(peerId, scope: scope);
    if (response == null) return FlowNameAvailability.unavailable;
    final flows = FlowSummary.listFromResponse(response, scope: scope);
    if (flows == null) return FlowNameAvailability.unverified;
    // 主机按名字原样建 scope（`flow:DEV` 和 `flow:dev` 是两行），所以查重也
    // 必须精确比。新建对话框为了少让人踩坑另外做了不区分大小写的提示，但那
    // 是 UI 层的保守策略，不能拿来决定「这个名字到底占没占」。
    return flows.any((flow) => flow.name == name)
        ? FlowNameAvailability.taken
        : FlowNameAvailability.free;
  }
}

/// 新建空白流程的骨架。
///
/// 空 `steps` 是合法的（`validate` 只检查容器自己的 `steps` 不能为空，不管根
/// 层），所以主机肯收；之后每一步都靠结构操作加进去。
class FlowBlankFlow {
  FlowBlankFlow._();

  static String skeleton(String name) => 'flow: $name\nversion: 1\nsteps: []\n';
}
