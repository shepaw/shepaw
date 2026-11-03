import '../../peer/services/hub_flow.dart';
import 'flow_edit_ops.dart';

/// 内置模板。文案放客户端：M1.5 之后 `flow_list` 会带上 `description`，但内置
/// 模板可能被用户改过（主机「库里有就不覆盖」），所以名单一律按 **模板 id** 认。
class FlowTemplateEntry {
  const FlowTemplateEntry({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.blurbZh,
    required this.blurbEn,
  });

  final String id;
  final String titleZh;
  final String titleEn;
  final String blurbZh;
  final String blurbEn;
}

/// 模板名单。和 `crates/api/src/flow/builtin.rs::templates()` 对齐 —— 主机那边
/// 加模板时这里要跟着加，否则画廊里看不到。
class FlowTemplateCatalog {
  FlowTemplateCatalog._();

  static const builtins = [
    FlowTemplateEntry(
      id: 'builtin-review-loop',
      titleZh: '实现 → 评审',
      titleEn: 'Implement → review',
      blurbZh: '写、审、不过就返工，最多 3 轮后汇总',
      blurbEn: 'Write, review, rework until it passes, then summarise',
    ),
    FlowTemplateEntry(
      id: 'builtin-stage-gate',
      titleZh: '阶段关卡',
      titleEn: 'Stage gate',
      blurbZh: '两道关卡：每一步让人确认通过 / 返工 / 中止',
      blurbEn: 'Two gates: a person approves, reworks or aborts each step',
    ),
    FlowTemplateEntry(
      id: 'builtin-lead',
      titleZh: '领队拆解',
      titleEn: 'Lead breakdown',
      blurbZh: '交给领队自己拆成若干步再执行',
      blurbEn: 'Let the lead break the goal into steps at run time',
    ),
  ];
}

/// 从另一份流程变出新流程（模板 / 复制 / 另存为都走这条）。
class FlowFlowFrom {
  FlowFlowFrom._();

  /// 取一份定义的 yaml；拿不到返回 null。
  static Future<String?> sourceYaml(
    HubFlow client,
    String host,
    String scope,
    String sourceName,
  ) async {
    final got = await client.get(host, sourceName, scope: scope);
    return got?.yaml;
  }

  /// 把定义头里的 `flow:` 改成新名字。
  ///
  /// 走主机的 `header` 操作，顺带白拿一份带树和诊断的结果 —— 不自己在客户端改
  /// YAML（`flow` 字段不给用户在表单里改，两边会不一致）。
  static Future<String?> rename(
    HubFlow client,
    String host,
    String yaml,
    String newName,
  ) async {
    final result = await client.edit(host, yaml, [
      FlowEditOps.header('flow', newName),
    ]);
    return result.result?.yaml;
  }
}
