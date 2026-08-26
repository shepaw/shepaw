## 5. 排障与 FAQ

### 连接失败排查清单

1. 检查网络：远端 Agent / 云端服务是否可达；Ollama 是否在跑（`http://localhost:11434`）。
2. 核对 Server URL 与 Token（远端 ACP）/ 端口与白名单（Peer / 隧道）。
3. 在添加/编辑 Agent 界面点「**测试连接**」诊断。
4. 本地 Agent 离线 → 检查 `shepaw system.info`、Agent 状态图标（🟢在线 / ⚪离线 / 🟡连接中 / 🔴错误）。
5. 外网 Peer 连不上 → 确认 PC 端 Channel 隧道已连（设置 → 隧道，或 `shepaw meta system.info`）。
6. 离线消息收不到 → 确认收件箱投递后 App 上线会自动拉取（`GET /inbox/replies`），多等几秒或重进会话。
7. 仍不行 → 看日志：**设置 → 关于 → 查看日志**；提交反馈：**设置 → 关于 → 反馈**。

### 常见问题速答

- **Q：如何连接本地 Ollama？** 装 Ollama → `ollama pull <model>` → 添加本地 LLM Agent 选 Ollama → 填 `http://localhost:11434` → 测试连接。
- **Q：Planning 和 Flow 有什么区别？** Planning 由用户逐任务审核后执行；Flow 由系统自动分阶段驱动、可暂停/跳步/中止。Planning 适合要人工把关，Flow 适合全自动。
- **Q：怎么提高聊天速度？** 用本地模型减少网络延迟；缩小上传文件；流式响应默认开启；关闭不必要的多模态分析。
- **Q：支持离线吗？** 本地 Agent（Ollama）完全离线；云端 Agent 需网络；看历史聊天与设置无需网络。
- **Q：怎么删 Agent？** Agent 列表长按 → 删除（聊天记录保留）。
- **Q：群组里 Admin 干嘛的？** 分析需求、生成计划（Planning/Flow）、协调成员、整合结果。
- **Q：API Key 安全吗？** 主密码加密存本地安全存储；别分享主密码或备份文件；定期更换 Key。
