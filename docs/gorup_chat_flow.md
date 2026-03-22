这是个很有意思的设计问题。基于对现有代码的理解，我来分享一些想法和建议：                           
                                                                                                     
  ---                                                                                                
  现状分析                                                                                           
                                                                                                     
  当前实现已有：                                                                                     
  - ExecutionPlan / PlanTask 带依赖关系 (dependencies 字段)
  - Admin 角色 + @mention 路由机制
  - TaskStatus 状态机 (pending → inProgress → done/failed/skipped)
  - planningMode 开关和 maxLoopRounds 控制

  缺口：缺少将计划与消息路由强绑定的"流程执行引擎"。

  ---
  流程控制语法设计建议

  核心设计原则

  Admin 生成的计划不仅是"任务列表"，而是一份可执行的流程描述，由 Hub 端负责解析和调度。

  流程控制语法草案（JSON）

  {
    "plan_id": "plan_001",
    "steps": [
      {
        "id": "s1",
        "type": "sequential",
        "tasks": [
          { "id": "t1", "assignee": "agent_a", "instruction": "...", "timeout": 30 }
        ]
      },
      {
        "id": "s2",
        "type": "parallel",
        "tasks": [
          { "id": "t2", "assignee": "agent_b", "instruction": "..." },
          { "id": "t3", "assignee": "agent_c", "instruction": "..." }
        ],
        "join": "all"  // all | any | n_of_m
      },
      {
        "id": "s3",
        "type": "conditional",
        "condition": { "task_id": "t2", "status": "done" },
        "on_true": "s4",
        "on_false": "s5"
      }
    ]
  }

  核心节点类型：
  - sequential - 串行，前一个完成才触发下一个
  - parallel - 并行，按 join 策略汇合
  - conditional - 条件分支，基于任务结果
  - loop - 循环，带退出条件
  - human_gate - 暂停等待用户审批

  ---
  架构层设计

  用户提问
    ↓
  Admin 规划 → 输出 FlowPlan（结构化 JSON）
    ↓
  FlowExecutor（新组件，在 Hub/ChatService 层）
    ├── 解析 FlowPlan
    ├── 维护执行状态机
    ├── 按串/并行规则调度消息发送
    └── 监听 Agent 响应 → 更新状态 → 触发下一步
    ↓
  Admin 订阅执行事件 → 可注入控制指令（暂停/跳过/重试）

  关键新增组件

  1. FlowExecutor (lib/services/flow_executor.dart)
  - 持有 FlowPlan 和当前执行游标
  - 并行任务用 Future.wait 组合
  - 串行任务用 async/await 链式触发

  2. Admin 的实时监控
  - 在 Admin 的 system prompt 中注入"流程观察员"角色
  - Admin 收到每个步骤的执行摘要
  - Admin 可通过特定指令影响 FlowExecutor：
  [FLOW_CTRL] action=pause|resume|skip step=s2
  [FLOW_CTRL] action=retry task=t3
  [FLOW_CTRL] action=inject step=s3 message="重新评估方向"

  3. 结果聚合策略
  - parallel 步骤完成后，可由 Admin 聚合多个 Agent 结果，再决策下一步
  - 或配置 auto_merge: true 由系统自动汇总

  ---
  与现有代码的整合路径
  ┌────────────────────────────────────┬───────────────────────────┐
  │              现有代码              │         扩展方向          │
  ├────────────────────────────────────┼───────────────────────────┤
  │ ExecutionPlan.tasks[].dependencies │ 升级为 FlowPlan 的有向图  │
  ├────────────────────────────────────┼───────────────────────────┤
  │ GroupActiveTask                    │ 扩展为 FlowExecutionState │
  ├────────────────────────────────────┼───────────────────────────┤
  │ _handleAdminGroupMessage           │ 识别 [FLOW_CTRL] 指令     │
  ├────────────────────────────────────┼───────────────────────────┤
  │ PlanApprovalCard                   │ 增加 FlowPlan 预览和审批  │
  ├────────────────────────────────────┼───────────────────────────┤
  │ TaskBoardWidget                    │ 实时展示流程执行进度      │
  └────────────────────────────────────┴───────────────────────────┘
  ---
  需要重点讨论的设计决策

  1. FlowPlan 的生成方式：纯 LLM 输出 JSON，还是 LLM + 结构化解析 + 用户确认？
  2. Admin 的"实时干预"触发条件：轮询式 vs 事件驱动？
  3. 并行任务的 join 策略：某个 Agent 失败时如何处理整个并行块？
  4. 流程存储：是否需要持久化 FlowPlan 以支持中断恢复？

  你最想先落地哪个部分？