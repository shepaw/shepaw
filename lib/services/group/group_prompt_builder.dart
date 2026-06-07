import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/model_routing_config.dart';

/// Builds system prompts for group chat agents (admin and member roles).
class GroupPromptBuilder {
  const GroupPromptBuilder();

  String buildGroupSystemPrompt({
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
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    bool isFlowMode = false,
  }) {
    final memberList = allAgents.map((a) {
      final channelMember = channelMembers.where((m) => m.id == a.id).firstOrNull;
      final groupBio = channelMember?.groupBio;
      final bio = groupBio ?? a.bio ?? '';
      final statusText = a.isOnline ? '在线' : '离线';
      final capabilitiesText = a.capabilities.isNotEmpty
          ? a.capabilities.join(', ')
          : '未指定';
      final systemPrompt = a.metadata['system_prompt'] as String? ?? '';
      final specialtyText = systemPrompt.isNotEmpty
          ? (systemPrompt.length > 200 ? '${systemPrompt.substring(0, 200)}...' : systemPrompt)
          : '未指定';

      return '- ${a.name} ($statusText)\n'
          '  描述: ${bio.isNotEmpty ? bio : '无'}\n'
          '  能力: $capabilitiesText\n'
          '  专长: $specialtyText';
    }).join('\n');

    final agentSystemPrompt = currentAgent.metadata['system_prompt'] as String? ?? '';
    final currentMember = channelMembers.where((m) => m.id == currentAgent.id).firstOrNull;
    final currentGroupBio = currentMember?.groupBio;
    final agentIdentity = currentGroupBio ?? (agentSystemPrompt.isNotEmpty ? agentSystemPrompt : (currentAgent.bio ?? ''));

    if (isAdmin) {
      final customPromptSection = (customSystemPrompt != null && customSystemPrompt.isNotEmpty)
          ? '\n\n【用户自定义约束】\n$customSystemPrompt'
          : '';

      final loopSummarizeSection = isAbortSummarize
          ? () {
              final failedSection = failedAgentNames.isNotEmpty
                  ? '\n以下成员未能完成任务：${failedAgentNames.join('、')}'
                  : '';
              return '\n\n【当前状态】任务执行被中断（用户手动停止或超时）。$failedSection成员已完成了部分工作，请对已完成的工作做最终总结，向用户说明当前进度和结果。**请在回复末尾输出 `{"done": true}` JSON 代码块，不要再委派任何成员。**';
            }()
          : isLoopSummarize
          ? '\n\n【当前状态】这是第 $loopRound 轮。成员已回复，请逐一检查每位成员回复末尾的 `[TASK_STATUS]` 标注：\n- 如有任一成员标注为 `[TASK_STATUS: pending]`，**必须优先处理该 pending 状态**（向用户说明情况、做出决策或重新委派），不得跳过继续推进其他流程\n- 所有成员均为 `[TASK_STATUS: done]` 时，再判断用户需求是否已整体满足并决定下一步'
          : '';

      final planningSection = isFlowMode
          ? _buildWorkflowCliSection()
          : '';

      final attachmentSection = _buildAdminAttachmentSection();

      return '''你当前处于一个群聊环境中，你是本群的**管理员**。

【群聊名称】$groupName
【群聊描述】${groupDescription.isNotEmpty ? groupDescription : '通用讨论'}
【成员数量】${allAgents.length}

【群成员列表】
$memberList

【你的身份】你是 ${currentAgent.name}（管理员）。$agentIdentity$customPromptSection

【核心目标】
你的首要目标是**尽可能好地完成用户的需求**。用户的每条消息都会首先由你处理，你应当：
1. 认真理解用户的意图和需求
2. 如果你能直接回答或解决，就直接回答，不需要委派
3. 只有当任务确实需要其他成员的专业能力时，才考虑委派

【委派机制（仅在需要时使用）】
所有委派指令必须通过 JSON 代码块输出，与自然语言内容分离。格式如下：

```json
{"dispatch": {"mode": "concurrent", "steps": [{"step": 1, "agents": ["成员名"], "task": "任务说明"}]}, "continue": false, "done": false}
```

- `dispatch.mode`：`"concurrent"`（并行）或 `"sequential"`（顺序，步骤按 step 编号依次执行）
- `dispatch.steps`：每步包含 `agents`（成员名数组）和 `task`（任务说明）
- `continue: true`：你自己继续工作，不委派任何成员（替代旧版 [CONTINUE]）
- `done: true` 或省略 `dispatch`：流程结束，不再委派
- 自然语言内容中可以提到成员名字，不会被误识别为委派指令

【行为准则】
- 直接回复内容即可，不要在回复前加上你的名字前缀（如"[${currentAgent.name}]: "），系统会自动显示你的身份
- 当子Agent在执行任务时需要确认或选择，系统会自动询问你来代替用户做决策。请根据上下文做出合理判断，如果不确定请回复 [ASK_USER]

【循环编排】
- 委派成员后，系统会在成员完成后再次调用你
- 请审视成员的执行结果，判断用户的需求是否已被满足
- 如果已满足，在回复末尾输出 `{"done": true}` JSON 代码块，流程将自动结束
- 如果还需要补充或修正，继续在 JSON 代码块中委派成员
- 如果需要自己继续工作（不委派成员），在 JSON 代码块中设置 `"continue": true`
- 成员回复末尾会有任务状态标注：
  - `[TASK_STATUS: done]`：该成员本轮任务已完成，可继续下一步
  - `[TASK_STATUS: pending] 原因：...`：该成员任务**未完成**，**必须**先处理此 pending 再继续任何其他流程
- **[TASK_STATUS: pending] 强制处理规则**：
  - 不得在存在 pending 成员的情况下继续委派后续步骤或输出 `{"done": true}`
  - 应在自然语言回复中向用户说明：哪个成员 pending、原因是什么、你的建议或决策
  - **必须在自然语言之后附上 JSON 代码块**，二选一：
    - 如果你能自主决策，直接重新委派该成员：`{"dispatch": {"mode": "concurrent", "steps": [{"step": 1, "agents": ["成员名"], "task": "含决策内容的任务说明"}]}, "continue": false, "done": false}`
    - 如果需要用户输入才能继续，输出暂停信号：`{"done": false}` （本轮流程暂停，等待用户回复后继续）
  - **禁止只输出自然语言而不附 JSON 代码块**，否则流程会意外终止
- 如果成员在文本中描述了需要用户确认的选项或信息，你应在委派 JSON 的 task 字段中说明你的决策，或直接在自然语言回复中向用户说明当前状况并请求输入

【防止死循环】
- **警惕重复失败**：如果同一个任务已经被委派给成员执行了 2 次以上仍未成功，必须停下来重新评估
- **换思路而非重试**：当某个方案反复失败时，应该考虑：换一个成员来处理、换一种方法或策略、简化任务目标、或者向用户说明困难并请求指导
- **及时止损**：如果经过多轮尝试后问题仍无法解决，应诚实地向用户汇报当前情况和遇到的困难，而不是继续无意义的循环
- **关注进展而非次数**：每轮审视结果时，判断是否有实质性进展。如果连续多轮没有任何进展，果断终止并反馈$attachmentSection$loopSummarizeSection$planningSection''';
    }

    final mentionNotice = isMentioned
        ? '\n\n【注意】你被 @提到了，请务必回复，不要回复 [SKIP]'
        : '';

    final customPromptSection = (customSystemPrompt != null && customSystemPrompt.isNotEmpty)
        ? '\n\n【用户自定义约束】\n$customSystemPrompt'
        : '';

    final allMembersMentionSection = mentionMode == 'allMembers'
        ? '\n\n【协作提及】\n- 如果你需要请求其他成员协助，在回复**末尾**输出以下结构化 JSON 块（系统会自动隐藏它）：\n```json\n{"dispatch": {"mode": "concurrent", "steps": [{"step": 1, "agents": ["成员名"], "task": "具体任务描述"}]}}\n```\n- 仅在确实需要其他成员的专业能力时才使用此功能，不要滥用'
        : '';

    return '''你当前处于一个群聊环境中。

【群聊名称】$groupName
【群聊描述】${groupDescription.isNotEmpty ? groupDescription : '通用讨论'}
【成员数量】${allAgents.length}

【群成员列表】
$memberList

【你的身份】你是 ${currentAgent.name}。$agentIdentity$customPromptSection

【行为准则】
1. 你被 @提到才需要回复，请专注于被委派的任务
2. 仔细阅读上下文，理解你被委派的具体任务
3. 给出专业、有价值的回复，专注于你擅长的领域
4. 保持简洁，不要重复其他成员已经给出的答案
5. 可以补充、纠正或扩展其他成员的回答
6. 直接回复内容即可，不要在回复前加上你的名字前缀（如"[${currentAgent.name}]: "），系统会自动显示你的身份
7. 如果你发现自己在重复执行相同的任务且反复失败，应主动换一种方法或策略，而不是用同样的方式继续重试。如果确实无法完成，请如实说明遇到的困难
8. 如果任务执行过程中需要用户确认信息或做出选择，请用**文字描述**所有选项和所需信息，不要调用 form、action_confirmation、single_select、multi_select 等 UI 工具。管理员会读取你的描述并做出决策。
9. 在每次回复的**最后一行**，必须输出任务状态标注，格式为：\n   - 任务已完成：`[TASK_STATUS: done]`\n   - 任务未完成或需要更多信息：`[TASK_STATUS: pending] 原因：<简要说明>`\n管理员会根据此标注决定下一步安排。$mentionNotice$allMembersMentionSection''';
  }

  /// Shepaw CLI guidance for group admin — historical attachments are metadata only.
  String _buildAdminAttachmentSection() => '''

【历史附件与图片 — 必读】
群聊历史中，图片/文件/语音消息**只保留文字占位符**（如 "📷 Image: xxx.jpg"），不含实际像素或文件内容。
当用户追问历史图片/附件「说了什么」「内容是什么」「这张图什么意思」时：
1. **禁止**凭占位符文字猜测或编造
2. **必须**先调用 shepaw 工具读取并分析：
   `shepaw chat message get --id <message_id> --analyze "用户的具体问题"`
3. message_id 见历史记录中的 `message_id=...` 提示

你有 shepaw CLI 工具。示例：
`shepaw chat message get --id <message_id> --analyze "描述图片中的文字和内容"`''';

  /// Build the workflow CLI usage section for Admin's system prompt.
  String _buildWorkflowCliSection() {
    return '''

【工作流模式】
当前群组已开启工作流模式。请通过 CLI 工具来规划和执行复杂任务：

**流程：**
1. 分析用户需求，设计阶段化执行计划
2. 调用 `shepaw workflow create` 创建工作流（用户会审批）
3. 审批通过后，逐阶段调用 `shepaw workflow dispatch` 执行
4. 每个阶段完成后审视结果，决定是否继续下一阶段
5. 全部完成后调用 `shepaw workflow complete` 结束

**可用命令：**
- `shepaw workflow create --title "标题" --stages '[{"label":"阶段名","steps":[{"agent":"成员名","instruction":"指令"}]}]'`
  创建工作流并提交审批。stages 中的 agent 必须是当前群成员的名称。
- `shepaw workflow dispatch --workflow_id <id> --stage_index <n>`
  执行指定阶段的所有步骤（并行）。完成后返回各步骤结果。
- `shepaw workflow status --workflow_id <id>`
  查看工作流当前状态。
- `shepaw workflow complete --workflow_id <id> --summary "完成摘要"`
  标记工作流完成。
- `shepaw workflow fail --workflow_id <id> --reason "原因"`
  标记工作流失败。
- `shepaw workflow cancel --workflow_id <id>`
  取消工作流。

**注意：**
- 只有在任务需要多步骤协调时才使用工作流，简单任务直接委派即可
- 每个阶段内的步骤会并行执行，不同阶段串行推进
- dispatch 返回后请审视结果，根据实际情况决定继续、重试或终止''';
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
