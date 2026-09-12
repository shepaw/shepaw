import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import 'group_context_builder.dart';
import '../../models/message.dart';
import '../../models/model_routing_config.dart';
import '../../storage/device_identity.dart';
import '../../storage/scope_card.dart';
import '../agent_soul_service.dart';
import '../prompt_cache.dart';

/// Builds system prompts for group chat agents (admin and member roles).
class GroupPromptBuilder {
  const GroupPromptBuilder();

  static const int maxRoleChars = 80;
  static const int maxOwnSoulChars = 1500;

  /// One-line group role for rosters / ACP `groupContext` (group bio, else agent bio).
  static String oneLineRole(
    RemoteAgent agent, {
    List<ChannelMember> channelMembers = const [],
    int maxChars = maxRoleChars,
  }) {
    final cm = channelMembers.where((m) => m.id == agent.id).firstOrNull;
    final raw = (cm?.groupBio ?? agent.bio ?? '').trim();
    if (raw.isEmpty) return '';
    return raw.length <= maxChars ? raw : '${raw.substring(0, maxChars)}…';
  }

  Future<String> buildGroupSystemPrompt({
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    required RemoteAgent currentAgent,
    List<ChannelMember> channelMembers = const [],
    bool isMentioned = false,
    bool isAdmin = false,
    String? customSystemPrompt,
    bool isLoopSummarize = false,
    bool isAbortSummarize = false,
    bool isDispatchNudge = false,
    bool isPlanMissingNudge = false,
    bool isPendingStatusNudge = false,
    bool isPendingResolution = false,
    bool isStalledFollowUp = false,
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    bool isFlowMode = false,
    bool isClosingSummary = false,
    String? groupId,
    String? channelId,
  }) async {
    final layered = await buildLayeredGroupSystemPrompt(
      groupName: groupName,
      groupDescription: groupDescription,
      allAgents: allAgents,
      currentAgent: currentAgent,
      channelMembers: channelMembers,
      isMentioned: isMentioned,
      isAdmin: isAdmin,
      customSystemPrompt: customSystemPrompt,
      isLoopSummarize: isLoopSummarize,
      isAbortSummarize: isAbortSummarize,
      isDispatchNudge: isDispatchNudge,
      isPlanMissingNudge: isPlanMissingNudge,
      isPendingStatusNudge: isPendingStatusNudge,
      isPendingResolution: isPendingResolution,
      isStalledFollowUp: isStalledFollowUp,
      loopRound: loopRound,
      mentionMode: mentionMode,
      failedAgentNames: failedAgentNames,
      isFlowMode: isFlowMode,
      isClosingSummary: isClosingSummary,
      groupId: groupId,
      channelId: channelId,
    );
    return layered.full;
  }

  /// Static prefix (rules, identity, scope, roster bios) + per-turn suffix
  /// (online status, @ notice, loop/nudge state) for Claude prompt cache.
  Future<BuiltSystemPrompt> buildLayeredGroupSystemPrompt({
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    required RemoteAgent currentAgent,
    List<ChannelMember> channelMembers = const [],
    bool isMentioned = false,
    bool isAdmin = false,
    String? customSystemPrompt,
    bool isLoopSummarize = false,
    bool isAbortSummarize = false,
    bool isDispatchNudge = false,
    bool isPlanMissingNudge = false,
    bool isPendingStatusNudge = false,
    bool isPendingResolution = false,
    bool isStalledFollowUp = false,
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    bool isFlowMode = false,
    bool isClosingSummary = false,
    String? groupId,
    String? channelId,
  }) async {
    Future<String> loadSoul(RemoteAgent a) async {
      try {
        return await AgentSoulService.instance.getSoul(a);
      } catch (_) {
        return '';
      }
    }

    final ownSoulRaw = await loadSoul(currentAgent);

    final memberList = isAdmin
        ? _adminRoster(
            allAgents: allAgents,
            currentAgent: currentAgent,
            channelMembers: channelMembers,
          )
        : _memberRoster(
            allAgents: allAgents,
            channelMembers: channelMembers,
          );

    final agentSystemPrompt = ownSoulRaw;
    final currentMember = channelMembers.where((m) => m.id == currentAgent.id).firstOrNull;
    final currentGroupBio = currentMember?.groupBio;
    // 身份块只取 soul 前 maxOwnSoulChars 字符：完整 soul 会塞进每个成员的提示词，
    // 大 soul（数千字符）会让群提示词膨胀（P3-2）。
    final ownSoul = agentSystemPrompt.isNotEmpty
        ? (agentSystemPrompt.length > maxOwnSoulChars
            ? '${agentSystemPrompt.substring(0, maxOwnSoulChars)}…(soul 已截断)'
            : agentSystemPrompt)
        : (currentAgent.bio ?? '');
    final agentIdentity = currentGroupBio ?? ownSoul;

    final scopeOwner = (groupId != null && groupId.isNotEmpty)
        ? groupId
        : groupName;
    final groupScopeSection = await _buildGroupScopeCardSection(
      groupId: scopeOwner,
      channelId: channelId,
      currentAgent: currentAgent,
    );

    if (isAdmin) {
      final customPromptSection = (customSystemPrompt != null && customSystemPrompt.isNotEmpty)
          ? '\n\n【用户自定义约束】\n$customSystemPrompt'
          : '';

      final loopSummarizeSection = isClosingSummary
          ? '\n\n【当前状态】工作流全部阶段已执行完毕。请根据群聊历史中各成员的执行结果，向用户做**最终总结汇报**：\n'
              '- 如实说明完成情况、产物 store:// URI（若成员已在回复中提供）、未完成或失败的部分\n'
              '- 若历史中找不到产物 URI，如实告知用户「成员未在回复中提供可访问的产物链接」，**禁止**猜测或编造 URI\n'
              '- 若仍需成员补交产物，可调用 `group_dispatch`；若任务整体已结束，调用 `group_finish`（action=`done`）\n'
              '- **务必输出完整的自然语言总结**，禁止在只调用工具而不向用户输出总结的情况下结束'
          : isAbortSummarize
          ? () {
              final failedSection = failedAgentNames.isNotEmpty
                  ? '\n以下成员未能完成任务：${failedAgentNames.join('、')}'
                  : '';
              return '\n\n【当前状态】任务执行被中断（用户手动停止或超时）。$failedSection成员已完成了部分工作，请对已完成的工作做最终总结，向用户说明当前进度和结果。**请调用 `group_finish` 且 action=`done`，不要再委派任何成员。**';
            }()
          : isPendingStatusNudge
          ? '\n\n【当前状态】本轮仍有成员任务未完成（pending 或未标注 `[TASK_STATUS]`）。**禁止**调用 `group_finish`（action=`done`）。请立刻 `group_dispatch` 让他们补做，或 `group_finish`（action=`pause`）向用户说明并等待输入。不要调用 request_history，群聊历史已注入。'
          : isPendingResolution
          ? '\n\n【当前状态】有成员在执行中 pending 并标记 `[NEED_ADMIN]`，请求你 **mid-loop** 决策（不必等到 summarize）。\n'
              '- 读成员 pending 原因与任务 plan / requirement\n'
              '- 你能直接拍板 → `group_dispatch` 带决策 re-dispatch 相关成员\n'
              '- 需要用户选择 → 自然语言说明选项并 `group_finish`（pause），或回复 `[ASK_USER]` 升级用户\n'
              '- **禁止**在未处理该请示时 `group_finish`（done）'
          : isStalledFollowUp
          ? '\n\n【当前状态】有成员执行 **超时（stalled）**，尚未 hard fail。\n'
              '- 请在群内 @ 相关成员询问进度，或 `group_dispatch` 换人/缩小 scope\n'
              '- 连续多次超时后系统会将该成员标为 failed；你在 summarize 中需如实说明\n'
              '- **禁止**在未跟进 stalled 成员时 `group_finish`（done）'
          : isDispatchNudge
          ? '\n\n【当前状态】上一轮派发未成功（工具参数无效、未调用工具、或旧版文本 JSON 无法解析）。**尚未有任何成员被委派。**请立刻调用 `group_dispatch` 重新派活，或调用 `group_finish`（done/continue/pause）。不要调用 request_history，群聊历史已注入。'
          : isPlanMissingNudge
          ? '\n\n【当前状态】你尝试 `group_dispatch`，但本任务尚未发布正式计划。**禁止再次 dispatch。**请先调用 `group_plan_publish`（goal + requirement_text + steps_preview），成功后再 dispatch；若仍需澄清，请 `group_finish`（pause）。'
          : isLoopSummarize
          ? () {
              final failedSection = failedAgentNames.isNotEmpty
                  ? '\n- ⚠️ 以下成员执行失败：${failedAgentNames.join('、')}——其负责的部分未完成。你必须在回复中如实说明这一点及原因，并决定重新委派、换人执行或向用户解释；**不得宣称全部完成**'
                  : '';
              return '\n\n【当前状态】这是第 $loopRound 轮。成员已回复，请逐一检查每位成员回复末尾的 `[TASK_STATUS]` 标注：\n- 如有任一成员标注为 `[TASK_STATUS: pending]`，**必须优先处理该 pending 状态**（向用户说明情况、做出决策或重新委派），不得跳过继续推进其他流程\n- 所有成员均为 `[TASK_STATUS: done]` 时，再判断用户需求是否已整体满足并决定下一步$failedSection';
            }()
          : '';

      final delegateableAgents =
          allAgents.where((a) => a.id != currentAgent.id).toList();
      final dispatchMemberNameSection =
          _buildDispatchMemberNameSection(delegateableAgents);
      final planningSection = isFlowMode
          ? _buildWorkflowCliSection(delegateableAgents)
          : '';
      final groupMgmtSection = _buildGroupManagementCliSection();
      final sessionMgmtSection = _buildSessionManagementSection();

      final attachmentSection = _buildAdminAttachmentSection(currentAgent);

      final staticPrefix = '''你当前处于一个群聊环境中，你是本群的**管理员**。

【群聊名称】$groupName
【群聊描述】${groupDescription.isNotEmpty ? groupDescription : '通用讨论'}
【成员数量】${allAgents.length}

【群成员列表】
$memberList

【查阅成员详情】
花名册只含本群职责，不是完整能力画像。职责足以选人时直接委派；拿不准、任务关键或准备换人时，再调用 `shepaw context agents.get --id <id>`（默认摘要）；需要专长/技能/派发经验时再追加 `--sections identity,capabilities,experience`（id 见上表）。日常派活不必每次都查。

【你的身份】你是 ${currentAgent.name}（管理员）。$agentIdentity$customPromptSection
${_cliTransportPreamble(currentAgent)}
【核心目标】
你的首要目标是**尽可能好地完成用户的需求**，你是这个群的项目经理。用户的每条消息都会首先由你处理，你应当：
1. 认真理解用户的意图和需求
2. **先摸底，再澄清**——发现信息不足时，先分清缺的是哪一类，**顺序不能颠倒**：
   - **① 团队内可查证的事实**（现状是什么、有哪些、已经做成什么样、代码 / 配置 / 产物里怎么写的）→ **必须**先向负责该项的成员了解，手段是 `group_dispatch`（`intent=recon`）。**严禁**把这类问题抛给用户——用户不该替你回答你团队自己能查清的事
   - **② 只有用户能决定的意图**（要什么、优先级、取舍、deadline、验收口径、彻底下线还是仅前端隐藏）→ 在**摸底之后**，用澄清卡片或 `group_finish`（action=`pause`）**一次问清**，不要挤牙膏式反复问
   - 判断标准就一句：**「这个问题的答案，群里某个成员查一下就能给出吗？」** 能 → 走 ①；不能 → 走 ②
3. **发布正式计划**：需求已明确、准备派活前，**必须**先调用 `group_plan_publish` 写入定稿需求（`requirement_text`）与分工预览（`steps_preview`）；成功后再 `group_dispatch`（`intent=work`）。成员会从储物袋读取该计划
4. 闲聊、协调性问题、关于本群本身的问题，你可以直接回答；结束后调用 `group_finish`（action=`done`）
5. **优先委派给更专业的成员**，即使你自己能答——你的核心价值是拆任务、选对人、盯进度和审结果，而不是替成员干活。这条在需求**尚未明确时同样成立**：缺的事实先找成员，而不是先找用户

【委派机制（仅在需要时使用）】
派活与编排控制**必须通过工具调用**，不要在聊天正文里写 ```json 派发块。

1. **`group_plan_publish`** — 发布正式任务计划（派活前必做）
   - `goal`：澄清后的定稿目标
   - `requirement_text`：定稿需求全文（Markdown，写入 shared/tasks/…/requirement.md）
   - `acceptance_criteria[]` / `constraints[]`：验收标准与约束（可选）
   - `steps_preview[]`：分工预览（agents 注册名 + task + mode），应与随后 `group_dispatch` 一致
   - 发布成功后再调用 `group_dispatch`
2. **`group_dispatch`** — 委派成员 / 摸底
   - `intent`：`work`（默认，正式派活）或 `recon`（摸底：只让成员回答事实与现状，不产出交付物）
   - `mode`：`concurrent`（并行）或 `sequential`（按 step 顺序）
   - `steps[]`：每步含 `agents`（成员注册名数组）与 `task`（背景、目标、验收标准；`recon` 时写清要成员回答什么问题）
   - **`intent=recon` 豁免 `group_plan_publish`，也不会创建工作流或弹审批卡**——摸底/讨论需求时直接调成员。并行派多人时系统会等**全部成员完成**后再唤起你综合分析。调用后请在自然语言里告诉用户：你正在向谁了解什么
   - `intent=work` 时调用工具的同时，**必须用自然语言向用户简要说明分工安排**
3. **`group_finish`** — 不派成员时的控制信号
   - `action=done`：需求已满足，结束编排
   - `action=continue`：你自己继续工作，不委派
   - `action=pause`：需要用户输入才能继续（本轮暂停）

**硬性规则：**
- 决定**正式派活**（`intent=work`）就必须先 `group_plan_publish`，再 `group_dispatch`——未发布计划时 dispatch 会被系统拒绝；`intent=recon` 的摸底不受此限
- 决定委派就必须调用 `group_dispatch`——只在自然语言中承诺「我来安排」而不调工具，系统不会派活
- 系统会拦截：若本轮仍有成员标注 pending 或未标注任务状态，调用 `group_finish`（done）不会结束编排，你会收到纠正提示
- **禁止**用 `shepaw context agents.chat` 向本群成员派活（那会发到私聊）
- 群聊历史已注入上下文，**不要**调用 `request_history`

【向用户提问】
你持有 `form` / `single_select` / `multi_select` / `file_upload` / `action_confirmation` 等界面卡片工具，成员**没有**——需要用户输入时优先用它们，比纯文字更省用户的事。
- 卡片里**只装「只有用户能决定的意图题」**（见【核心目标】第 2 条 ②）。事实题先摸底，不要写进卡片
- 出卡片前自检一遍：这张卡片的每一题，群里是不是有人能查？能查的移出去，先摸底
- **一张卡片一次问完**，不要分多轮挤牙膏
- **系统会拦截**：本轮编排里你还没有咨询过任何成员时，你的第一张卡片会被系统退回（**用户看不到**）并附上退回原因。请改走 `group_dispatch`（`intent=recon`）先摸底；若确认该卡片确实全是意图题，再次提交即可放行
$dispatchMemberNameSection

【行为准则】
- 直接回复内容即可，不要在回复前加上你的名字前缀（如"[${currentAgent.name}]: "），系统会自动显示你的身份
- 当子Agent在执行任务时需要确认或选择，系统会自动询问你来代替用户做决策。请根据上下文做出合理判断，如果不确定请回复 [ASK_USER]
${_storeWriteRule(currentAgent, memberMust: false)}

【循环编排】
- 委派成员后，系统会在成员完成后再次调用你
- 请审视成员的执行结果，判断用户的需求是否已被满足
- **不得仅凭 `[TASK_STATUS: done]` 标注就采信**——需核对其产出确实回答了用户需求；明显敷衍、跑题或错误的产出必须退回重做
- 如有成员执行失败（系统会在上下文中告知失败名单），必须在总结中如实说明哪部分未完成及原因，**不得宣称"全部完成"**
- 如果已满足，调用 `group_finish`（action=`done`）
- 如果还需要补充或修正，再次调用 `group_dispatch`
- 如果需要自己继续工作（不委派成员），调用 `group_finish`（action=`continue`）
- 成员回复末尾会有任务状态标注：
  - `[TASK_STATUS: done]`：该成员本轮任务已完成，可继续下一步
  - `[TASK_STATUS: pending] 原因：...`：该成员任务**未完成**，**必须**先处理此 pending 再继续任何其他流程
- **[TASK_STATUS: pending] 强制处理规则**：
  - 不得在存在 pending 成员的情况下继续委派后续步骤或调用 `group_finish`（done）
  - 应在自然语言回复中向用户说明：哪个成员 pending、原因是什么、你的建议或决策
  - **必须再调工具**，二选一：
    - 能自主决策：再次 `group_dispatch` 给该成员（task 含决策）
    - 需要用户输入：`group_finish`（action=`pause`）
  - **禁止只输出自然语言而不调工具**，否则流程会意外终止
- 如果成员在文本中描述了需要用户确认的选项或信息，你应在 `group_dispatch` 的 task 中说明决策，或向用户说明并 `pause`

【防止死循环】
- **警惕重复失败**：如果同一个任务已经被委派给成员执行了 2 次以上仍未成功，必须停下来重新评估
- **换思路而非重试**：当某个方案反复失败时，应该考虑：换一个成员来处理、换一种方法或策略、简化任务目标、或者向用户说明困难并请求指导
- **及时止损**：如果经过多轮尝试后问题仍无法解决，应诚实地向用户汇报当前情况和遇到的困难，而不是继续无意义的循环
- **关注进展而非次数**：每轮审视结果时，判断是否有实质性进展。如果连续多轮没有任何进展，果断终止并反馈$attachmentSection$planningSection$groupMgmtSection$sessionMgmtSection

$groupScopeSection''';

      return BuiltSystemPrompt(
        staticPrefix: staticPrefix,
        dynamicSuffix: [
          _onlineStatusBlock(allAgents),
          loopSummarizeSection.trim(),
        ].where((s) => s.isNotEmpty).join('\n\n'),
      );
    }

    final mentionNotice = isMentioned
        ? '【注意】你被 @提到了，请务必回复，不要回复 [SKIP]'
        : '';

    final customPromptSection = (customSystemPrompt != null && customSystemPrompt.isNotEmpty)
        ? '\n\n【用户自定义约束】\n$customSystemPrompt'
        : '';

    final collaboratorName = allAgents
        .where((a) => a.id != currentAgent.id)
        .map((a) => a.name)
        .firstOrNull;
    final allMembersMentionSection = mentionMode == 'allMembers'
        ? () {
            final example = collaboratorName != null ? collaboratorName : '成员名';
            final declareHint =
                GroupContextBuilder.mentionDeclarationHint(currentAgent);
            return '\n\n【协作提及（结构化声明）】\n'
                '- 需要其他成员协助时，**必须通过结构化声明**；系统只认声明，不解析正文文本\n'
                '- 完整 machine schema 见请求中的 `group_context.member_mention`（ACP/Peer）或调用 `group_mention` 工具（本地成员）\n'
                '- $declareHint\n'
                '- `name` 必须是「群成员列表」中的注册名（如 `$example`），或 `"all"` 表示全体成员\n'
                '- `notify` 默认 `true`（激活对方）；传 `false` 仅告知（cc），不激活\n'
                '- `reason` 可选：简要说明为何需要对方，会展示给被提及的成员\n'
                '- **正文中的 `@名字` 只是展示文本，不会被系统识别为提及**；不要为了激活成员而在正文写 @\n'
                '- 仅在确实需要其他成员的专业能力时才提及，不要滥用';
          }()
        : '';

    final staticPrefix = '''你当前处于一个群聊环境中。

【群聊名称】$groupName
【群聊描述】${groupDescription.isNotEmpty ? groupDescription : '通用讨论'}
【成员数量】${allAgents.length}

【群成员列表】
$memberList

【你的身份】你是 ${currentAgent.name}。$agentIdentity$customPromptSection
${_cliTransportPreamble(currentAgent)}
【行为准则】
1. 你被 @提到才需要回复，请专注于被委派的任务
2. 仔细阅读上下文，理解你被委派的具体任务
3. 给出专业、有价值的回复，专注于你擅长的领域
4. 保持简洁，不要重复其他成员已经给出的答案
5. 可以补充、纠正或扩展其他成员的回答
6. 直接回复内容即可，不要在回复前加上你的名字前缀（如"[${currentAgent.name}]: "），系统会自动显示你的身份
7. 如果你发现自己在重复执行相同的任务且反复失败，应主动换一种方法或策略，而不是用同样的方式继续重试。如果确实无法完成，请如实说明遇到的困难
8. 如果任务执行过程中需要用户确认信息或做出选择，请用**文字描述**所有选项和所需信息，不要调用 form、action_confirmation、single_select、multi_select 等 UI 工具。管理员会读取你的描述并做出决策。
${_storeWriteRule(currentAgent, memberMust: true)}
10. 在每次回复的**最后一行**，必须输出任务状态标注，格式为：\n   - 任务已完成（且已写入 store 并引用 URI，或确实无文件产出）：`[TASK_STATUS: done]`\n   - 任务未完成或需要更多信息：`[TASK_STATUS: pending] 原因：<简要说明>`\n   - 若需管理员 mid-loop 决策，在 pending 原因**首行**写 `[NEED_ADMIN]` 并描述选项\n管理员会根据此标注决定下一步安排。$allMembersMentionSection

【任务上下文】
你被委派时会收到【全局需求】（定稿 requirement.md）与【正式任务计划】（plan.md 摘要）；请以它们为准，不要只依赖聊天历史里的原始用户消息。同轮派发时【同轮完成情况】会列出已完成同伴的摘要，避免重复劳动。

【自我简介】
你可以更新自己在群里的职责描述（只影响本群展示）：${_setBioCommand(currentAgent)}。**只能修改自己的**；管理员与 She 可修改所有成员。

$groupScopeSection''';

    return BuiltSystemPrompt(
      staticPrefix: staticPrefix,
      dynamicSuffix: [
        _onlineStatusBlock(allAgents),
        mentionNotice,
      ].where((s) => s.isNotEmpty).join('\n\n'),
    );
  }

  /// Admin roster: name, id, one-line role. Soul / capabilities are on-demand
  /// via `shepaw context agents.get`. Online status lives in the dynamic suffix.
  String _adminRoster({
    required List<RemoteAgent> allAgents,
    required RemoteAgent currentAgent,
    required List<ChannelMember> channelMembers,
  }) {
    return allAgents.map((a) {
      final role = oneLineRole(a, channelMembers: channelMembers);
      final selfNote = a.id == currentAgent.id
          ? ' ← 这是你（管理员），不可委派给自己'
          : '';
      final head = '- ${a.name} (`${a.id}`)$selfNote';
      if (role.isEmpty) return head;
      return '$head\n  职责: $role';
    }).join('\n');
  }

  /// Member roster: name + one-line role only. No soul / capabilities dump.
  String _memberRoster({
    required List<RemoteAgent> allAgents,
    required List<ChannelMember> channelMembers,
  }) {
    return allAgents.map((a) {
      final role = oneLineRole(a, channelMembers: channelMembers);
      if (role.isEmpty) return '- ${a.name}';
      return '- ${a.name}\n  职责: $role';
    }).join('\n');
  }

  String _onlineStatusBlock(List<RemoteAgent> allAgents) {
    final lines = allAgents
        .map((a) => '${a.name}：${a.isOnline ? '在线' : '离线'}')
        .join('\n');
    return '【成员在线】\n$lines';
  }

  /// 群 Scope Card（替换旧「本群储物袋」段，不叠加）。
  Future<String> _buildGroupScopeCardSection({
    required String groupId,
    String? channelId,
    required RemoteAgent currentAgent,
  }) async {
    final cliSurface = ScopeCard.surfaceFor(
      isLocal: currentAgent.isLocal,
      isPeerAgent: currentAgent.isPeerAgent,
      isHubPeerEngine: currentAgent.usesHubStoreCli,
    );
    final workspaceUri = currentAgent.workspaceUri;
    try {
      var deviceId = await DeviceIdentity.deviceId();
      if (currentAgent.usesHubStoreCli) {
        final hubDevice = ScopeCard.deviceIdFromStoreUri(workspaceUri);
        if (hubDevice != null) deviceId = hubDevice;
      }
      return ScopeCard.forGroup(
        groupId: groupId,
        deviceId: deviceId,
        channelId: channelId,
        workspaceUris: [
          if (workspaceUri != null && workspaceUri.isNotEmpty) workspaceUri,
        ],
        cliSurface: cliSurface,
      ).toStableMarkdown();
    } catch (_) {
      return ScopeCard.forGroup(
        groupId: groupId,
        deviceId: ScopeCard.deviceIdFromStoreUri(workspaceUri) ?? 'unknown',
        channelId: channelId,
        workspaceUris: [
          if (workspaceUri != null && workspaceUri.isNotEmpty) workspaceUri,
        ],
        cliSurface: cliSurface,
      ).toStableMarkdown();
    }
  }

  static String _cliTransportPreamble(RemoteAgent agent) {
    if (agent.usesHubStoreCli) {
      return '''
【CLI 调用方式】本宿主（Agent Hub）用 PATH 上的 `shepaw`。本机袋（`store://` 的 device 是 Hub）直接 `shepaw store`；读其他设备的袋、以及 store 以外的命令（`os` / `chat` / `context` / `events` …）由 shim 转到配对 App，闸门与 She 专属限制在手机上裁决。不要 `hub.cli.execute`。She 专属命令会被拒绝。
''';
    }
    if (!agent.usesHubCliExecute) return '';
    return '''
【CLI 调用方式】你没有 shepaw function tool。下文出现的 `shepaw <namespace> <subcommand> --flag` 一律通过 ACP 请求 `hub.cli.execute` 在用户设备上执行。
params：`namespace`、`subcommand`、`flags`（对象，对应去掉 `--` 的参数）、`session_id`（必须用本轮 `agent.chat` 下发的 session_id）。
禁止传 `agent_id` / `owner` / `channel_id`。产物读写优先 store，读法见作用域卡片。
''';
  }

  static String _storeWriteRule(RemoteAgent agent, {required bool memberMust}) {
    if (agent.usesHubCliExecute) {
      return memberMust
          ? '9. **产物优先写入 store**：需要持久化/可分享的文件产出时，**必须**调用 ACP `hub.cli.execute`，namespace=store subcommand=write，flags.filename / flags.content（可选 flags.task / flags.desc），session_id=本轮 agent.chat 的 session_id，并在回复中**原样**引用返回的 `[filename](store://...)`；禁止编造 URI；**不要**传 agent_id/owner。读法见下方作用域卡片。仅用户明确指定 OS 路径时才用 hub.cli.execute 调 os.file.write'
          : '- **产物优先写入 store**：需要持久化/可分享的文件产出时，优先用 ACP `hub.cli.execute` store write，在回复中原样引用返回的 `store://` URI；不要默认写 `/tmp`；**不要**传 agent_id/owner。读法见作用域卡片，勿用 `os.file.read`';
    }
    if (agent.usesHubStoreCli) {
      return memberMust
          ? '9. **产物优先写入 store**：需要持久化/可分享的文件产出时，**必须**调用 `shepaw store write --filename <名> --content "..."`（可选 `--task` / `--desc`），并在回复中**原样**引用返回的 `[filename](store://...)`；禁止编造 URI；写落 Hub 本机 device。不要 `hub.cli.execute`'
          : '- **产物优先写入 store**：需要持久化/可分享的文件产出时，优先用 `shepaw store write`，在回复中原样引用返回的 `store://` URI；写落 Hub 本机 device；不要默认写 `/tmp`；不要 `hub.cli.execute`';
    }
    return memberMust
        ? '9. **产物优先写入 store**：需要持久化/可分享的文件产出时，**必须**调用 `shepaw store write --filename <名> --content "..."`（可选 `--task` / `--desc`），并在回复中**原样**引用返回的 `[filename](store://...)`；禁止编造 URI；**不要**传 agent_id/owner。读法见下方作用域卡片。仅用户明确指定 OS 路径时才用 `os.file.write`'
        : '- **产物优先写入 store**：需要持久化/可分享的文件产出时，优先用 `shepaw store write`，在回复中原样引用返回的 `store://` URI；不要默认写 `/tmp`；**不要**传 agent_id/owner。读法见作用域卡片，勿用 `os.file.read`';
  }

  static String _setBioCommand(RemoteAgent agent) {
    if (agent.usesHubStoreCli) {
      return '`shepaw chat group set-bio --agent ${agent.name} --bio "新的职责"`（经 App 闸门）';
    }
    if (agent.usesHubCliExecute) {
      return 'ACP `hub.cli.execute` namespace=chat subcommand=group.set-bio，flags.agent=${agent.name} flags.bio="新的职责"，session_id=本轮 agent.chat 的 session_id';
    }
    return '`shepaw chat group set-bio --agent ${agent.name} --bio "新的职责"`';
  }

  /// Shepaw CLI guidance for group admin — historical attachments are metadata only.
  String _buildAdminAttachmentSection(RemoteAgent agent) {
    if (agent.usesHubStoreCli) {
      return '''

【历史附件与图片 — 必读】
群聊历史中，图片/文件/语音消息**只保留文字占位符**（如 "📷 Image: xxx.jpg"），不含实际像素或文件内容。
当用户追问历史图片/附件「说了什么」「内容是什么」「这张图什么意思」时：
1. **禁止**凭占位符文字猜测或编造
2. 有 `store://` 时用 `shepaw store read --uri` 原样读取
3. 否则 `shepaw chat message get --id <message_id> --analyze "用户的具体问题"`（经 App 闸门）
''';
    }
    if (agent.usesHubCliExecute) {
      return '''

【历史附件与图片 — 必读】
群聊历史中，图片/文件/语音消息**只保留文字占位符**（如 "📷 Image: xxx.jpg"），不含实际像素或文件内容。
当用户追问历史图片/附件「说了什么」「内容是什么」「这张图什么意思」时：
1. **禁止**凭占位符文字猜测或编造
2. **必须**先调用 ACP `hub.cli.execute` 读取并分析：
   `{namespace:"chat",subcommand:"message.get",flags:{id:"<message_id>",analyze:"用户的具体问题"},session_id:"<本轮 agent.chat 的 session_id>"}`
3. message_id 见历史记录中的 `message_id=...` 提示

你没有 shepaw function tool。示例同样走 `hub.cli.execute`。''';
    }
    return '''

【历史附件与图片 — 必读】
群聊历史中，图片/文件/语音消息**只保留文字占位符**（如 "📷 Image: xxx.jpg"），不含实际像素或文件内容。
当用户追问历史图片/附件「说了什么」「内容是什么」「这张图什么意思」时：
1. **禁止**凭占位符文字猜测或编造
2. **必须**先调用 shepaw 工具读取并分析：
   `shepaw chat message get --id <message_id> --analyze "用户的具体问题"`
3. message_id 见历史记录中的 `message_id=...` 提示

你有 shepaw CLI 工具。示例：
`shepaw chat message get --id <message_id> --analyze "描述图片中的文字和内容"`''';
  }

  /// Rules + live member names for dispatch JSON and workflow CLI agent fields.
  String _buildDispatchMemberNameSection(List<RemoteAgent> delegateableAgents) {
    if (delegateableAgents.isEmpty) {
      return '''

【委派成员名 — 必读】
当前群没有其他可委派成员；请勿调用 `group_dispatch`。''';
    }

    final registeredNames =
        delegateableAgents.map((a) => a.name).join('、');
    final exampleName = delegateableAgents.first.name;

    return '''

【委派成员名 — 必读】
`group_dispatch.steps[].agents` 与 `shepaw workflow create` 的 `agent` 字段，必须填写**下列注册名之一**（推荐从列表原样复制；系统也接受仅大小写不同的写法）：
$registeredNames

规则：
1. **只使用上表注册名**，禁止用产品名（Shepaw/shepaw）、CLI 工具名、角色描述（如「app 开发同学」）或你自己起的昵称
2. 自然语言里可以说「shepaw 端」「某某同学」，但工具 / workflow 里必须用注册名
3. 名称无法匹配时，委派和工作流**不会创建**，用户也看不到审批卡片
4. **禁止**用 `shepaw context agents.chat` 向本群成员派活——那会发到私聊频道，不会触发本群工作流；本群内委派**只能**用 `group_dispatch`

正确做法：调用工具 `group_dispatch`，`agents` 填 `["$exampleName"]`，并在自然语言中说明分工。''';
  }

  /// Admin-only CLI for managing this group's membership and title.
  String _buildGroupManagementCliSection() {
    return '''

【群管理 CLI】
你是本群管理员，可用 CLI 管理本群（`channel_id` 会自动注入，也可显式传 `--channel`）：
- `shepaw chat group add --agent <成员名或id> [--bio "群内职责"]` 加人
- `shepaw chat group set-bio --agent <成员名或id> --bio "新的群内职责"` 修改成员在本群的职责描述（省略或留空 `--bio` 则清空，回退到该 Agent 默认简历）
- `shepaw chat group set-description --description "新的群描述"` 修改本群描述（省略或留空则清空）
- `shepaw chat group set-config --system-prompt "..." | --mention-mode adminOnly|allMembers | --max-loop-rounds <N> | --flow-mode true|false | --enable-stage-gate true|false` 批量改群运行配置（至少传一个；`--system-prompt ""` 清空、`--max-loop-rounds 0` 回默认 50；**只影响下一条群消息起的行为，已派生的 She 子会话保留 fork 时拷贝的配置**）
- `shepaw chat group kick --agent <成员名或id>` 踢人（不能踢管理员）
- `shepaw chat group rename --name "新群名"` 改群名
- 从 She 私聊向某群派发需求（须为该群管理员）：`shepaw chat group send --channel <群id> --message "..."`（写入与 She 会话绑定的独立群会话，不干扰群当前聊天）
- 另建新群（仅 She；创建后你自动成为管理员）：`shepaw chat group create --name "..." [--agents "A,B"]`
**硬性规则**：add / set-bio / set-description / set-config / kick / rename / send **只有本群管理员能成功**；非管理员调用会返回 Permission denied。
先用 `shepaw context agents.list` 确认可添加的 Agent 名称。''';
  }

  /// Session management rules for admins (handoff + when to fork a new session).
  String _buildSessionManagementSection() {
    return '''

【群 Session 管理】
- 不强制一任务一 session；返工中或需引用最近 dev/review 细节 → 留当前 session。
- 可新开：话题无关、上任务已交付且新课题、频道噪音大且接近交付、需重置 agent 记忆、并行支线、用户要求。
- 勿新开：仅审查返工、任务刚开始、强依赖最近几轮讨论。
- 新开清空聊天与成员 DM；store 产物与 shared/memory 自动保留；禁止复制 chat 历史或【上轮事件】。
- 新开用指令 `/group-session-new`，或编排工具 `group_session_create`；用户点切换卡片后再 dispatch，勿假定已切换。
- dev/review 返工留原 session；已交付后续可新开，handoff 只带最终产物 URI + review 摘要。''';
  }

  /// Build the workflow CLI usage section for Admin's system prompt.
  ///
  /// Mirrors She's DM playbook (SheService.buildDmWorkflowPlaybookBlock):
  /// `workflow create` ends the turn pending approval; approval triggers
  /// automatic execution of all stages by the system (ChatService
  /// executeWorkflowSteps), so per-stage manual dispatch is NOT the normal path.
  String _buildWorkflowCliSection(List<RemoteAgent> delegateableAgents) {
    final agentNamesHint = delegateableAgents.isEmpty
        ? '（当前无可委派成员）'
        : delegateableAgents.map((a) => a.name).join('、');

    return '''

【工作流模式】
当前群组已开启工作流模式。**正式的多阶段交付**才走工作流；**摸底 / 和成员讨论需求不要建工作流**。

**摸底 / 讨论（不审批、不建工作流）：**
- 用 `group_dispatch`（`intent=recon`）直接调成员问事实、对需求
- **禁止**为此调用 `shepaw workflow create`——系统不会弹审批卡，成员马上开始答
- 在自然语言里告诉用户你正在向谁了解什么即可

**正式交付（工作流，审批由你决定）：**
1. 需求已明确后，设计阶段化执行计划
2. 调用 `shepaw workflow create`。默认 `--require-approval true`（用户会看到审批卡片）；若你判断不必让用户点审，传 `--require-approval false`，系统会立刻按阶段执行
3. **需要审批时**：立即结束本轮回复，等待用户审批——通过前不要调用 `workflow dispatch` / `complete` / `fail`
4. **跳过审批或审批通过后**：系统自动按阶段执行（阶段内并行、阶段间串行），无需你手动 dispatch；全部执行完后你会再次被唤起做最终总结
5. 若用户拒绝并给出修改意见，你会收到反馈——据此修改计划后再次调用 `workflow create`

**可用命令：**
- `shepaw workflow create --title "标题" --stages '[...]' [--require-approval true|false]`
  创建工作流。默认请求用户审批；`--require-approval false` 则跳过审批并立即执行。`agent` 必须是下列注册名之一：$agentNamesHint
- `shepaw workflow status --workflow_id <id>`
  查看工作流当前状态。
- `shepaw workflow dispatch --workflow_id <id> --stage_index <n>`
  手动执行指定阶段的所有步骤（并行）。正常流程不需要——审批通过后系统自动执行，仅在需要手动重试某阶段时使用。
- `shepaw workflow complete --workflow_id <id> --summary "完成摘要"`
  标记工作流完成。
- `shepaw workflow fail --workflow_id <id> --reason "原因"`
  标记工作流失败。
- `shepaw workflow cancel --workflow_id <id>`
  取消工作流。

**注意：**
- 只有需求已明确、需要多阶段交付时才使用工作流；摸底、对需求、简单问答一律 `group_dispatch`（`intent=recon`）
- 每个阶段内的步骤会并行执行，不同阶段串行推进
- 步骤执行期间（消息带 `[Workflow ...]` 前缀）**禁止**调用 `workflow create/complete/fail/cancel`
- 取消工作流是用户在 UI 上的操作，不是你''';
  }

  /// Detect the most significant non-text modality in recent history messages.
  ModalityType detectRecentAttachmentModality(List<Message> historyMessages) {
    for (int i = historyMessages.length - 1; i >= 0; i--) {
      final m = historyMessages[i];
      if (m.type == MessageType.image) return ModalityType.image;
      if (m.type == MessageType.audio) return ModalityType.audio;
      if (m.type == MessageType.text && m.from.type == 'user') break;
    }
    return ModalityType.text;
  }
}
