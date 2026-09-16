/// Store URI references for task requirements (Phase J).
///
/// User goal text lives in `requirement.md`; prompts only carry pointers.
class GroupRequirementRef {
  GroupRequirementRef._();

  static String adminUserGoalBlock(String uri) =>
      '[用户目标（requirement.md）]\n'
      '定稿需求见 `$uri`（请 store read 获取全文；此处不重复用户原文）。';

  static String memberGlobalPlaceholder(String uri) =>
      '（定稿需求见 `$uri`，请 store read 后执行）';
}
