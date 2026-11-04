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

  /// 流程库引用（`call.flow`）：同 scope 的流程列表里选，不手敲 `lib/x@2`。
  flowRef,
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

/// 主机 `set` 操作能不能吃这个值。编辑器标红的值一律不能发 —— 否则 M1.5 会
/// 拒掉整批，连带把同一批里其他字段也标成 rejected。
bool isFlowFieldValueValid(FlowFieldSpec spec, Object? value) {
  if (value == null) return !spec.required;
  return switch (spec.shape) {
    FlowFieldShape.string ||
    FlowFieldShape.text =>
      value is String && value.trim().isNotEmpty,
    FlowFieldShape.int => value is int,
    FlowFieldShape.intOrInput => value is int ||
        (value is String &&
            RegExp(r'^\{\{\s*inputs\.[A-Za-z0-9_.-]+\s*\}\}$')
                .hasMatch(value)),
    FlowFieldShape.boolean => value is bool,
    FlowFieldShape.enumOf =>
      value is String && spec.options.contains(value),
    FlowFieldShape.cond => switch (value) {
        String text => text.trim().isNotEmpty,
        Map map =>
          map['judge'] is String &&
          (map['judge'] as String).trim().isNotEmpty &&
          map['ask'] is String,
        _ => false,
      },
    FlowFieldShape.listOf =>
      value is List && value.isNotEmpty &&
          value.every((e) => e is String && e.trim().isNotEmpty),
    FlowFieldShape.mapOf => value is Map &&
        value.isNotEmpty &&
        value.entries.every((e) =>
            e.key is String &&
            (e.key as String).trim().isNotEmpty &&
            e.value is String &&
            (e.value as String).trim().isNotEmpty),
    FlowFieldShape.outputMap => value is Map &&
        value.isNotEmpty &&
        value.entries.every((e) {
          if (e.key is! String || (e.key as String).trim().isEmpty) {
            return false;
          }
          final v = e.value;
          if (v is String) return v.trim().isNotEmpty;
          if (v is Map) {
            final options = v['enum'];
            return options is List && options.isNotEmpty;
          }
          return true; // 主机给的原始结构化值，原样保留
        }),
    FlowFieldShape.flowRef => value is String && value.trim().isNotEmpty,
  };
}
