/// 编辑过程中要告诉用户的事。
///
/// 控制器不碰 `BuildContext`，也不读 `AppLocalizations`：它只说"发生了什么"，
/// 文案由界面去配。这样控制器可以脱离 widget 单测。
enum FlowEditorNoticeKind {
  /// 主机没应答（10 秒超时或对端不可达）。
  hostNoReply,

  /// 主机拒了这一批操作，定义没变。
  editRejected,

  /// 保存被拒（多半是校验没过）。
  saveRejected,

  /// 还有 error 级诊断，不让保存。
  hasProblems,

  /// 保存成功，[FlowEditorNotice.count] 是新的版本号。
  saved,

  /// 保存被冲突检测拒了（create_only 撞名 / base_revision 落后）。
  /// [FlowEditorNotice.count] 是主机回的当前版本号 `latest`。
  saveConflict,

  /// 源码应用前校验就没过。
  sourceInvalid,
}

class FlowEditorNotice {
  const FlowEditorNotice(this.kind, {this.raw, this.count = 0});

  final FlowEditorNoticeKind kind;

  /// 主机给的原因原文（英文/中文混杂，直接摆给用户）。
  final String? raw;

  /// [FlowEditorNoticeKind.hasProblems] 是问题条数，[saved] 是版本号。
  final int count;
}
