# ShePaw Storage Node（M7）

无头 master 候选节点：实现 `store.*` 协议语义与 ACL，与 Flutter 端共用
[`docs/storage_protocol_spec.md`](../docs/storage_protocol_spec.md) 和
[`docs/storage_fixtures/`](../docs/storage_fixtures/)。

## 范围

- 路径规范化 + ACL；本机目录树 `list/meta/read/write/commit/delete/stats/recycle/import.*`
- `commit.retention`（`keep_last` / `gfs`）
- HTTP `/health`、`/store`（联调 JSON）
- **Noise IK 配对**：`/peer/ws`（信封 v2 + `Noise_IK_25519_ChaChaPoly_BLAKE2b`，prologue `shepaw-acp/2.1`）；device_id = Noise fingerprint
- **无头管理面** `/admin`：配对 QR/批准、用量、回收站、换机导入审批；token 或 loopback 鉴权

## 运行

```bash
cd storage-node
go test ./...
go run ./cmd/storage-node \
  -root /var/lib/shepaw-store \
  -listen :8787 \
  -name "nas-master" \
  -admin-token "$SHEPAW_ADMIN_TOKEN"
```

1. 打开 `http://127.0.0.1:8787/admin/`，点「开始配对」得到 `shepaw://peer?...` QR。
2. App 扫码发起配对；节点 `/admin` 出现入站请求后批准。
3. 配对成功后 App 可经 Noise 加密 WS 发送 store 控制帧。

身份文件：`<root>/.system/noise_identity.json`；配对表：`paired_peers.json`。
