import 'group_orchestration_features.dart';

/// One-shot backstop: the admin must consult a member before putting a
/// clarification card in front of the *user*.
///
/// Observed failure (`shepaw 项目开发`, 2026-09-11): the admin read two store
/// files, consulted nobody, and asked the user to enumerate which agent
/// engines had been hidden — a fact that lived with the `agent-bridge` owner
/// printed in its own roster. Structurally its only member-facing tool was
/// `group_dispatch`, hard-gated on a *finalized* plan, so fact-finding was
/// impossible without misrepresenting the requirement as settled; hence the
/// policy fixes (`GroupPromptBuilder` + the first-turn injection) and
/// `group_dispatch(intent=recon)`.
///
/// This gate covers the card case specifically, because that is the one the
/// user actually sees. The bounce happens at the tool-call site
/// (`GroupAgentExecutor`), so **nothing is persisted or emitted** — the user
/// never sees the card, and the admin gets the reason back as a tool result
/// inside the same multi-turn turn. After [GroupOrchestrationFeatures
/// .maxReconFirstBounces] bounces the card is allowed through, so a genuine
/// intent-only card costs one extra turn and is never blocked outright.
class GroupReconFirstGate {
  GroupReconFirstGate._();

  /// Interaction types that put a *question* in front of the user.
  ///
  /// `action_confirmation` and `file_upload` are deliberately excluded: they
  /// confirm an action or collect a file the admin cannot obtain elsewhere,
  /// rather than asking the user for a fact a member could look up.
  static const Set<String> guardedInteractionTypes = {
    'form',
    'single_select',
    'multi_select',
  };

  static bool isGuarded(String interactionType) =>
      guardedInteractionTypes.contains(interactionType);

  /// Whether to bounce instead of showing the card to the user.
  static bool shouldBounce({
    required bool isAdmin,
    required String interactionType,
    required bool hasDelegateableMembers,
    required bool membersConsulted,
    required int bounceCount,
  }) {
    if (!GroupOrchestrationFeatures.reconFirstBounce) return false;
    if (!isAdmin) return false;
    if (!isGuarded(interactionType)) return false;
    // Nothing to consult — a single-member group must still be able to ask.
    if (!hasDelegateableMembers) return false;
    if (membersConsulted) return false;
    return bounceCount < GroupOrchestrationFeatures.maxReconFirstBounces;
  }

  /// Tool-result body handed back to the admin for the bounced call.
  static String toolFeedback() => '[系统拦截] 这张卡片已退回，**用户看不到它**。'
      '本轮编排里你还没有向任何成员了解过情况，而卡片里的问题可能本就有成员能查清。'
      '请二选一：\n'
      '1. **先摸底**：用 `group_dispatch`（`intent=recon`）向负责的成员问清事实'
      '（现状是什么、有哪些、已经做成什么样、代码 / 配置 / 产物里怎么写的），'
      '拿到答案后再决定要问用户什么；\n'
      '2. **确认无误**：若卡片里每一题都**只有用户能决定**（意图、取舍、优先级、'
      'deadline、验收口径），原样重新提交即可放行。\n'
      '自检标准：「这个问题的答案，群里某个成员查一下就能给出吗？」能 → 走 1。';
}
