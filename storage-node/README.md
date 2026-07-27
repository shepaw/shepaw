# ShePaw Storage Node（M7）

无头 master 候选节点：实现 `store.*` 协议语义与 ACL，与 Flutter 端共用
[`docs/storage_protocol_spec.md`](../docs/storage_protocol_spec.md) 和
[`docs/storage_fixtures/`](../docs/storage_fixtures/)。

## 范围

- 路径规范化 + ACL 纯逻辑（与 Dart fixture 全绿）
- 本机目录树：`list` / `meta` / `read` / `write.begin|chunk` / `commit`（含 `retention`）/ `delete` / `stats` / `recycle.*`
- HTTP 健康检查 + 简易 JSON 控制口 `/store`（联调）
- **无头管理面** `/admin`：用量、回收站、**换机导入审批**；本机鉴权（admin token 或 loopback）
- Noise/WS 配对码仍为后续

## 运行

```bash
cd storage-node
go test ./...
go run ./cmd/storage-node \
  -root /var/lib/shepaw-store \
  -listen :8787 \
  -admin-token "$SHEPAW_ADMIN_TOKEN"
```

- 未设置 `-admin-token` / `SHEPAW_ADMIN_TOKEN` 时，`/admin` **仅允许 loopback**。
- 浏览器打开 `http://127.0.0.1:8787/admin/`，在页面填入 token（若已配置）。
- API：`GET /admin/api/stats`、`GET /admin/api/recycle`、`POST /admin/api/recycle/empty|restore`、`GET /admin/api/import/pending`、`POST /admin/api/import/grant|reject`、`GET /admin/api/import/grants`（`Authorization: Bearer <token>` 或 `X-Admin-Token`）。

配对码 / Noise 握手将在后续迭代接入。
