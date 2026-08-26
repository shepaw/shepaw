# 人脸识别使用指南（Face Recognition Guide）

> She 的"认人"能力从"看图说话"升级为「人脸 embedding + 余弦相似度」比对。
> 全部计算在设备端本地完成（隐私优先）。设计细节见 `.ai_workspace/FACE_RECOGNITION_ANALYSIS.md`。

## 快速开始

```bash
# 1. 查看引擎 / 相册状态（Debug 引擎说明未放模型文件）
shepaw vision status

# 2. 给一位家人建档（登记一张清晰正面照）
shepaw vision album.enroll --person "妈妈" --image /path/to/mom.jpg --relationship 妈妈 --caption 客厅基准照

# 3. 识别一张照片里的人
shepaw vision recognize --image /path/to/photo.jpg

# 4. 列出已登记家人
shepaw vision album.list
```

## 命令一览

| 命令 | flags | 说明 |
|---|---|---|
| `vision status` | — | 引擎可用性、阈值、相册规模 |
| `vision recognize` | `--image <path>\|--message_id <id>` `[--top 3]` | 识别图中所有人脸，返回 person/confidence/decision/证据照片/档案摘要 |
| `vision album.enroll` | `--person <名> --image <path>\|--message_id <id>` `[--relationship] [--caption]` | 登记基准照（同名人追加） |
| `vision album.list` | `[--json]` | 每位家人：照片数、档案摘要 |
| `vision album.remove` | `--person <name\|id>` | 删除家人及其全部参考照（含向量与照片文件） |
| `vision profile.build` | `--person <name\|id>` `[--refresh]` | 用视觉 LLM 从参考照构建/刷新结构化视觉档案 |
| `vision profile.get` | `--person <name\|id>` | 读取已存档案（未构建则为空） |

### 图片输入二选一

- `--image <本地路径>`：直接读文件。
- `--message_id <id>`：走聊天消息附件（与 `shepaw chat message get` 的 message_id 一致）。

## 决策含义（She 与用户）

```
score ≥ high      → recognized  已识别
high > score ≥ low → ambiguous   存疑（返回候选，结合档案判断）
score < low       → unknown      未知
```

- `unknown` / `ambiguous` 时 She 应**明说"不确定"**，不得凭感觉猜名字。
- `recognized` 返回的 `evidence_photo_id` 是命中参考照，`profile_summary` 是已构建的视觉档案摘要。

## 参考相册最佳实践

- 每人登记 **2–3 张**不同角度/场景/光线的清晰正面照，识别更稳（匹配按每人多照取最高分聚合）。
- 宝宝/儿童**长大变化**时，追加新照片即可（`album.enroll` 同名追加），不必重建。
- 换发型/戴眼镜后如频繁误判，补一张当前样子的照片。
- 删除家人用 `album.remove`（会同时清理向量库、照片行与照片文件）。

## 结构化视觉档案

`profile.build` 会调用视觉 LLM，从该家人的参考照抽取：

`ageGroup / hairStyle / glasses / typicalOutfit / distinguishingMarks / commonScenes / voice / addressTerms / notes`

- 需要至少 1 张参考照；未配置支持视觉的模型时会明确报错。
- `profile.get` 只读不重建；识别命中时会带上 `profile_summary` 供 She 描述佐证。

## 启用真实模型（可选）

默认使用 **Debug 引擎**（确定性伪 embedding，非生物特征，仅用于开发/测试）。
要启用 MobileFaceNet 真引擎：

1. 获取模型文件（约 8–10 MB）：
   ```bash
   # 需要网络 + 你自己批准的下载源；脚本会 sha256 校验
   FACE_MODEL_URL_ULTRAAFACE=<url> FACE_MODEL_URL_MOBILEFACENET=<url> tool/fetch_face_models.sh
   ```
2. 重启应用（或调用 `FaceEmbeddingEngineRegistry.reset()`）。
3. `shepaw vision status` 应显示 `engine.id = tflite-mobilefacenet`、`is_debug = false`。

> 注意：真实模型下载 = 获取外部二进制，请仅从可信来源获取；
> 记录 `fetch_face_models.sh` 中的 sha256 以启用校验。无模型时系统自动降级 Debug 引擎。

## She 的用法（对话中直接说）

- "这是谁？" → She 调 `vision recognize --message_id <id>`（或 `--image <path>`）
- "记住这是妈妈" → She 调 `vision album.enroll --person 妈妈 --message_id <id>`
- "妈妈长什么样" / "描述一下妈妈" → She 调 `vision profile.get --person 妈妈`（或先 `profile.build`）
- 认出后 She 会引用档案里的细节（发型、常穿、明显标识）佐证判断。

## 故障排查

| 现象 | 处理 |
|---|---|
| `status` 显示 `debug` | 未放模型文件；确认 `assets/models/face/` 或运行下载脚本 |
| `album.enroll` 报"未检测到人脸" | 换更清晰、正面、光照充足的照片；Debug 引擎整图视为一张脸，几乎总能"检测到" |
| `recognize` 全 `unknown` | 相册为空，或该人未建档；先 `album.enroll` |
| `profile.build` 报"未配置视觉模型" | 配置支持 image 的模型，或确认 She 的模型支持图片理解 |
| 误认 / 存疑 | 追加该人新角度照片；换装后补一张当前照片 |

## 数据与隐私

- embedding 与照片仅存本机：
  - `shepaw.db`：`face_persons` / `face_photos` 元数据（SQLite）。
  - 储物袋 `store://cognition/<device>/<she>/face_vectors/<photo_id>.json`：人脸 embedding 向量（逐照片一个 JSON 文件，与 Agent 记忆同生命周期——备份 / 恢复 / `store wipe` / 跨设备镜像统一）。
  - `<Documents>/shepaw/images/`：参考照原图。
- 无云端索引、无上传；`agent-bridge` / `channel` 不参与任何计算。
- 删除操作经 `album.remove` 会清理对应向量与照片文件。
- 旧的 veda SQLite 向量库（`veda_face_192.db`）已弃用，由储物袋 `cognition/` 形态取代。
