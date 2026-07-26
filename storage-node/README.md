# ShePaw Storage Node（M7）

无头 master 候选节点：实现 `store.*` 协议语义与 ACL，与 Flutter 端共用
[`docs/storage_protocol_spec.md`](../docs/storage_protocol_spec.md) 和
[`docs/storage_fixtures/`](../docs/storage_fixtures/)。

## 范围（本切片）

- 路径规范化 + ACL 纯逻辑（与 Dart fixture 全绿）
- 本机目录树：`list` / `meta` / `read` / `write.begin|chunk` / `commit` / `delete` / `stats` / recycle
- HTTP 健康检查 + 简易 JSON 控制口（便于联调；Noise/WS 配对码后续补齐）

> 说明：仓库内无 Go 版 agent-bridge（sibling 为 TypeScript）。本模块独立实现协议，不依赖共享 Go package。

## 运行

```bash
cd storage-node
go test ./...
go run ./cmd/storage-node -root /var/lib/shepaw-store -listen :8787
```

配对码 / Noise 握手将在后续迭代接入；当前可用 loopback JSON 口做 master 本地验证。
