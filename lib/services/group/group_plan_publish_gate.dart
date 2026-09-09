/// Hard gate: admin must call `group_plan_publish` before `group_dispatch`.
class GroupPlanPublishGate {
  GroupPlanPublishGate._();

  static String nudgeSystemContent() {
    return '[SYSTEM] 你调用了 `group_dispatch`，但本任务尚未发布正式计划。'
        '请先调用 `group_plan_publish` 写入定稿需求（requirement_text）与分工预览'
        '（steps_preview），成功后再 `group_dispatch`。若仍在澄清阶段，请 '
        '`group_finish`（action=`pause`）向用户提问。';
  }

  static String exhaustedWarning() {
    return '⚠️ 管理员尝试派活但未发布正式任务计划（group_plan_publish），本轮未派活。';
  }
}
