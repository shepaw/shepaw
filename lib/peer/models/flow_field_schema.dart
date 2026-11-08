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

  /// `task.model`：选中的 agent 的可用模型下拉。主机 schema 仍是 string，
  /// 形状由客户端覆盖（[FlowFieldCatalog]）。写入的是模型 id，或模板串。
  modelRef,

  /// `task.mode`：同上，走 `agent_modes_req` 拉到的模式列表。
  modeRef,

  /// 时长（`30s` / `2m` / `1h`）。界面是数字 + 单位；读到无法解析的旧值时
  /// 退回原样的文本框。
  duration,
}

class FlowFieldSpec {
  const FlowFieldSpec({
    required this.path,
    required this.shape,
    required this.labelZh,
    required this.labelEn,
    this.options = const [],
    this.required = false,
    this.group = 'advanced',
    this.helpZh,
    this.helpEn,
    this.optionLabels = const {},
    this.optionHelp = const {},
    this.defaultValue,
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

  /// 分组 id。界面按 kind 的分组表排序；表里没有的字段落到 `advanced`。
  final String group;

  /// 一行说明。获得焦点或值非法时才显示。
  final String? helpZh;
  final String? helpEn;

  /// 枚举值 → 短的人话（分段按钮 / 下拉第一行）。
  final Map<String, (String, String)> optionLabels;

  /// 枚举值 → 稍长的说明（下拉第二行，或分段按钮选中后显示在下方）。
  final Map<String, (String, String)> optionHelp;

  /// 空着时的默认。用来画「默认（xxx）」和判断高级摘要里要不要列出。
  final Object? defaultValue;

  String label(bool zh) => zh ? labelZh : labelEn;

  String? help(bool zh) {
    final text = zh ? helpZh : helpEn;
    if (text == null || text.isEmpty) return null;
    return text;
  }

  /// 枚举的短名。表里没有就退回原始值。
  String optionLabel(String value, bool zh) {
    final pair = optionLabels[value];
    if (pair == null) return value;
    return zh ? pair.$1 : pair.$2;
  }

  String? optionDetail(String value, bool zh) {
    final pair = optionHelp[value];
    if (pair == null) return null;
    final text = zh ? pair.$1 : pair.$2;
    return text.isEmpty ? null : text;
  }
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
            RegExp(r'^\{\{\s*inputs\.[A-Za-z0-9_.-]+\s*\}\}$').hasMatch(value)),
    FlowFieldShape.boolean => value is bool,
    FlowFieldShape.enumOf => value is String && spec.options.contains(value),
    FlowFieldShape.cond => switch (value) {
        String text => text.trim().isNotEmpty,
        Map map => map['judge'] is String &&
            (map['judge'] as String).trim().isNotEmpty &&
            map['ask'] is String,
        _ => false,
      },
    FlowFieldShape.listOf => value is List &&
        value.isNotEmpty &&
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
    FlowFieldShape.flowRef ||
    FlowFieldShape.modelRef ||
    FlowFieldShape.modeRef =>
      value is String && value.trim().isNotEmpty,
    // 只接受界面拼出来的 `30s`。读到的旧写法走原样文本框，和节点上的原值
    // 相同时由调用方放行，不在这里当成合法新值。
    FlowFieldShape.duration => value is String &&
        RegExp(r'^\d+\s*[smh]$').hasMatch(value.trim()),
  };
}
