/// 节点字段的「形状」（方案 M4）。
///
/// 主机 schema 只有 string / text / int / enum 四种标量，而 DSL 里还有列表、
/// 映射、布尔、条件、以及「数字或 inputs 引用」这些。这里把它们补齐，界面按
/// shape 选控件，产出的是主机 `set` 操作能直接吃的值。
enum FlowFieldShape {
  string,
  text,
  int,
  intOrInput,
  boolean,
  enumOf,
  cond,
  listOf,
  mapOf,
  outputMap,
}

class FlowFieldSpec {
  const FlowFieldSpec({
    required this.path,
    required this.shape,
    required this.labelZh,
    required this.labelEn,
    this.options = const [],
    this.required = false,
  });

  /// 点分路径，如 `task.prompt`。
  final String path;
  final FlowFieldShape shape;
  final String labelZh;
  final String labelEn;

  /// [FlowFieldShape.enumOf] 的候选项。
  final List<String> options;

  /// 必填字段清空时不发 null，界面上标红（M1.5 之前发出去会触发解析失败）。
  final bool required;

  String label(bool zh) => zh ? labelZh : labelEn;
}
