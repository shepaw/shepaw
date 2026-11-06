/// 把「用户的手势」翻译成 `flow_edit_req` 的操作。
///
/// 全是纯函数，不碰网络也不碰 widget，所以能直接单测 —— 这一层是整个编辑器
/// 里最容易写错的地方（`parent_id` / `index` / `branch` 差一个就改错节点），
/// 值得单独拎出来。
///
/// 操作词汇见主机 `crates/flow/src/edit.rs`：`set` / `insert` / `move` /
/// `delete` / `wrap` / `unwrap` / `header`。
class FlowEditOps {
  FlowEditOps._();

  /// 改节点上的一个字段。`value` 为 null 表示删掉这个键。
  static Map<String, dynamic> set(
    String nodeId,
    String field,
    Object? value,
  ) =>
      {'op': 'set', 'node_id': nodeId, 'field': field, 'value': value};

  /// 改定义头里的字段（`inputs` / `roles` / `limits` / `outputs` /
  /// `description` / `flow`）。点分路径可以写，比如 `limits.max_tasks`。
  static Map<String, dynamic> header(String field, Object? value) =>
      {'op': 'header', 'field': field, 'value': value};

  static Map<String, dynamic> delete(String nodeId) =>
      {'op': 'delete', 'node_id': nodeId};

  /// 插一个新节点。`parentId` 为空表示根层。
  ///
  /// 不传 `index` 就是追加（主机默认取列表长度）。`branch` 只有父节点是 `if`
  /// 时才有意义：`then` / `else`。
  static Map<String, dynamic> insert({
    required String parentId,
    required Map<String, dynamic> step,
    int? index,
    String? branch,
  }) =>
      {
        'op': 'insert',
        'parent_id': parentId,
        'step': step,
        if (index != null) 'index': index,
        if (branch != null) 'branch': branch,
      };

  /// 挪动一个节点：换父节点 + 换位置。
  ///
  /// 主机是先摘下来再插进去，所以「上移」就是插到 `index - 1`：摘掉自己之后
  /// 原来在 `index - 1` 的那个正好还在 `index - 1`，插进去就排到它前面。
  static Map<String, dynamic> move({
    required String nodeId,
    required String parentId,
    int? index,
    String? branch,
  }) =>
      {
        'op': 'move',
        'node_id': nodeId,
        'parent_id': parentId,
        if (index != null) 'index': index,
        if (branch != null) 'branch': branch,
      };

  /// 把节点包进一个新容器（主机的 `wrap` 只支持 `seq` / `par` / `loop`）。
  static Map<String, dynamic> wrap({
    required String nodeId,
    required String kind,
    required String wrapperId,
    int max = 3,
  }) =>
      {
        'op': 'wrap',
        'node_id': nodeId,
        'kind': kind,
        'wrapper_id': wrapperId,
        if (kind == 'loop') 'max': max,
      };

  /// 拆掉容器，把子步骤原地摊平。
  ///
  /// 只能用于 `seq` / `par` / `loop` / `map`：主机拆 `if` 时会把 `else` 整支
  /// 丢掉，所以界面上不该给 `if` 出这个按钮。
  static Map<String, dynamic> unwrap(String nodeId) =>
      {'op': 'unwrap', 'node_id': nodeId};

  /// 上一个兄弟是叶子时没法直接缩进：先把它包成 `seq`，再把当前节点挪进去。
  ///
  /// 两个操作必须同一批：主机的整批操作是原子的，拆开发的话中间态会被校验。
  static List<Map<String, dynamic>> indentIntoLeaf({
    required String nodeId,
    required String previousSiblingId,
    required String wrapperId,
    String kind = 'seq',
  }) =>
      [
        wrap(
          nodeId: previousSiblingId,
          kind: kind,
          wrapperId: wrapperId,
        ),
        move(nodeId: nodeId, parentId: wrapperId),
      ];

  /// 换节点类型（M1.5 的 `retype`）。
  ///
  /// **不要**自己拼「挪出子节点 → 清掉旧类型键 → 写新类型键 → 挪回去」：实测
  /// `seq`→`task` 时最后一步被拒；而为了绕开不传子节点的话，清掉旧类型键会
  /// 把整棵子树一起删掉。主机的 `retype` 保留 `id` / `desc` / `when` / `retry`
  /// / `timeout` / `on_error`，新旧都是容器时搬 `steps`，装不下就报错 —— 由界面
  /// 先提示用户处理。
  ///
  /// [body] 不给时主机用该类型的默认体。
  static Map<String, dynamic> retype({
    required String nodeId,
    required String kind,
    Map<String, dynamic>? body,
  }) =>
      {
        'op': 'retype',
        'node_id': nodeId,
        'kind': kind,
        if (body != null) 'body': body,
      };

  /// 往一个容器里加子步骤。空容器也能加：主机自己会建数组。
  ///
  /// `if` 要给 [branch]（`then` / `else`），否则新节点落在哪一支说不准。
  static Map<String, dynamic> insertChild({
    required String parentId,
    required Map<String, dynamic> step,
    String? branch,
  }) =>
      insert(parentId: parentId, index: 0, branch: branch, step: step);
}

/// 新建一个节点时给的默认值。
///
/// 必填字段给空串会立刻产出一条诊断 —— 这是故意的：诊断就是引导用户去填的
/// 提示，比我们自己在界面上拦一道更一致。
class FlowStepDefaults {
  FlowStepDefaults._();

  /// 某个类型的最小合法体。
  static Map<String, dynamic> body(String kind) => switch (kind) {
        'task' => {'prompt': ''},
        'seq' || 'par' || 'set' => <String, dynamic>{},
        'loop' => {'max': 3},
        'if' => {'cond': 'true'},
        'map' => {'over': ''},
        'call' => {'flow': ''},
        'gate' => {
            'ask': 'user',
            'options': ['ok', 'rework'],
          },
        'plan' => {'brief': ''},
        _ => <String, dynamic>{},
      };

  /// 一个完整的新步骤。
  static Map<String, dynamic> step(
    String id,
    String kind, {
    String prompt = '',
  }) {
    final spec = Map<String, dynamic>.from(body(kind));
    if (kind == 'task' && prompt.isNotEmpty) {
      spec['prompt'] = prompt;
    }
    return {'id': id, kind: spec};
  }

  /// 哪些类型的子步骤装在 `steps` / `then` 里，也就是能往里加子节点的。
  static bool isContainer(String kind) =>
      kind == 'seq' || kind == 'par' || kind == 'loop' || kind == 'map';

  /// 能不能往这个节点里放子节点（拖放用）。
  ///
  /// 比 [isContainer] 多一个 `if`：它虽然不能「拆」，但有两个槽（then / else）
  /// 能接收子节点。拆开 [canUnwrap] 仍刻意排除它 —— 主机拆 `if` 会丢掉 else。
  static bool acceptsChildren(String kind) => isContainer(kind) || kind == 'if';

  /// 能「拆开」的类型。刻意排除 `if`：主机会把 `else` 整支丢掉。
  static bool canUnwrap(String kind) => isContainer(kind);
}
