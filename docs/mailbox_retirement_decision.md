# 下线 Channel mailbox

状态：已确认。**轮 A 已提交（`35768a33`）**，轮 C / 轮 D 待做。总纲见 `docs/roadmap_host_authority.md`。
范围：App（`shepaw/lib`）+ Channel 服务端（轮 D 清理死代码）。主机侧不需要改 —— Rust 主机从来没有 channel mailbox 代码，`crates/orchestrate` 里的 `Inbox` 是群编排的 dispatch 文件，同名不同物。

## 裁定

1. **主机常开**。主机不在线时用户在 App 端发消息没有意义，因此「主机不可达时的存留转发」这项能力不需要，mailbox 整体下线。
2. **主机不可达 / busy 时直接给一条系统消息**（「主机不在线，消息没有发出」/「主机正忙，稍后再试」），不做本地排队重发。
3. **断线期间主机跑完的回复不能丢**。这条等于确认「ACP 路径必须先具备从主机拉 transcript 的能力」——见下方施工顺序里它被提到最前面。
   - 注意「App 本地要缓存」只能保住**断线前已经收到的部分**；断线期间主机新产生的那一段本地根本没见过，必须从主机取回。所以本地缓存是必要不充分条件，轮 B 躲不掉。
   - 本地库的定位随之从「权威」降级为「渲染缓存」，这也是整个新架构的方向。
4. **Channel 服务端的 mailbox 表一起清**（`/Users/edenzou/workspace/shepaw/channel`，另一个仓库），本仓库改完后它就是死代码。

## 背景：mailbox 今天在干什么

mailbox 不是「从主机读消息」的通道，而是**主机不可达时的第三方 store-and-forward**：

- 实际承载存储的是 **Channel 服务端**（`channel/pkg/internal/models/mailbox.go:50-72`，Gorm/SQLite，密文 TTL 7 天、每 target 500 条）。主机只是 claim 方，客户端本地库只是解密后的副本。
- 客户端侧 `mailbox_seal.dart` 做 E2E 加密（X25519 + HKDF + ChaCha20-Poly1305），中继只存密文看不到明文。
- 触发条件是**主机不可达或忙**：`agent_messaging_service.dart:671` 的 presence 探测（`authorized && (!online || busy)` 才投箱）、`:1012` 建连重试后仍失败、`:1487` agent 回 busy、群成员不可达 `group_agent_executor.dart:435`。

也就是说：一旦接受「主机常开 + 不可达就不用发」，mailbox 的全部触发条件都不复存在。

## 一个会影响施工顺序的发现

用户的判断——「消息权威在主机，客户端只拉数据」——**对 peer agent 已经成立，对 ACP agent 还没成立**：

| | 主机是否持有 transcript | 客户端怎么拿到消息 |
| --- | --- | --- |
| peer agent | 是 | 按游标增量拉：`agent_session_history_req`（cursor + limit + total，主机 `crates/api/src/agent.rs:856`），游标落 `peer_history_cursor` 表 |
| ACP agent | **否** | 客户端本地库是渲染源；每发一条消息还要把整段 history 打包发给主机（`agent_messaging_service.dart:1413` 的 `history: chatHistory` + `totalMessageCount`） |

而且 `agent_session_history_req` 目前挂在 **hub/peer 的帧路由**上（`crates/api/src/lib.rs:979`），ACP 那条 WS 上没有。

**这决定了 mailbox 不能立刻删**：它现在还兼着「后台期间主机跑完的回复，客户端回来补拉」这一职责（`chat_service.dart:699 drainAllMailboxReplies` 回前台全量收信、`chat_controller_load.dart:629` 进页补拉）。ACP 路径没有 transcript 拉取接口就先删，这段回复会直接丢。

## 施工顺序

把原来串起来的四轮拆成两组：**投信侧（轮 A）不依赖 transcript 拉取，可以立刻做；收信侧（轮 C）必须等轮 B。** 这样投信改造不用等主干工程，主干工程也有充分时间设计。

### 轮 A：拆投信侧 ✅ 已提交（`35768a33`）

删除：presence 路由 `_tryChannelInboxRoute`（`agent_messaging_service.dart:2301`）、建连失败的信箱兜底（`:1012-1026`）、busy 分支（`:1487-1503`）、群成员不可达 `_collectGroupMailboxReply`（`group_agent_executor.dart:435`）、投信主流程 `leaveMailboxAndCollect`（`:2358`）。
改为按裁定 2 直接落一条系统消息。做完之后 App 不再往 Channel 投任何信，只保留收信侧读历史的能力。

### 轮 B：让「主机持有 transcript」覆盖到 ACP agent

> **前提已修正**。我原先写「`agent_session_history_req` 只在 hub/peer 帧路由上，要把它挂到 ACP 上」——**这句是错的**。深挖后的地形见 `docs/session_history_authority_decision.md`，结论是：Rust 主机只有一个 WS 服务端点 `/peer/ws`，`agent_session_history_req` 就在 App 连进来的那条路的同一个 `match` 里（`shepaw-cli/crates/api/src/lib.rs:986`）；而 App 的 ACP 路径走的是 `/acp/ws` + JSON-RPC，是另一个东西。
> 因此轮 B 的形状取决于一个还没定的问题：**ACP 这条路要不要长期存在**。设计文档单独出，见上。

### 轮 C：拆收信侧（依赖轮 B）

删除：进页补拉（`chat_controller_load.dart:629-655`）、回前台 `drainAllMailboxReplies`（`chat_service.dart:692-728`）、WS 推送订阅（`chat_controller_load.dart:677-741`、`chat_controller.dart:259`）、`fetchMailboxReplies` 与四层去重（`chat_service.dart:3840-4018`）、`MailboxTurnClaims`、`MailboxInboxPoller` 的流重组。
这些职责由轮 B 的增量拉取接管。

### 轮 D：清场（依赖轮 C）

删 `lib/services/mailbox/`（5 个文件）、`group_mailbox_save_plan.dart`、相关测试（`test/mailbox/` 4 个 + `group_mailbox_save_plan_test.dart`），摘掉 `ChatService` 上暴露的 `leaveMailboxAndCollect` 接口。
库里已有消息的 `from_mailbox` / `mailbox_entry_id` 元数据**保留不动**——历史消息还要能渲染，只删代码不洗数据。
另按裁定 4 清 `shepaw/channel` 的 mailbox 表与相关路由（跨仓库，另立一轮）。

## 风险

- 轮 C 删掉 WS 推送后，App 在后台时不再有「主机主动推」的通道。主机常开 + 进页/回前台增量拉可以覆盖，但如果将来要「消息实时到达提醒」，得另做一条推送通道。
- 群聊成员不可达目前走 mailbox，删掉后该成员的回合会直接失败。群编排需要有对应的错误处理（这本来也更诚实：成员确实不可达）。
- 轮 B 之前存在一个中间态：轮 A 已经不投信了，但收信还靠 mailbox。此期间若主机不可达，消息发不出去也无法暂存——这是裁定的预期结果，不是回归。
