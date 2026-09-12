# 静态 JSON 更新（macOS / Android 旁加载）

客户端启动后会请求：

```text
https://release.shepaw.com/api/v1/latest-{platform}.json
```

`{platform}` 为 `macos` 或 `android`。这是普通 HTTPS 文件，不需要数据库或更新后端。

用户设置里只改**域名**（默认 `release.shepaw.com`），路径固定为 `/api/v1/latest-{platform}.json`。

## 字段约定

| 字段 | 必填 | 说明 |
|------|------|------|
| `version` | 是 | 三段版本号，如 `1.0.23`。不要写成 `1.0.23+1` |
| `buildNumber` | 是 | 与 `pubspec.yaml` 的 `+` 后一致，字符串或数字均可 |
| `downloadUrl` | 是 | 安装包的 HTTPS 直链 |
| `checksum` | 强烈建议 | `sha256:` + 64 位 hex。有则下载后校验，失败不安装 |
| `description` | 否 | 更新说明，会显示在对话框里 |
| `isMandatory` | 否 | `true` 时不能跳过 |
| `releaseDate` | 否 | ISO 8601，如 `2026-09-12T16:00:00Z` |
| `fileSize` | 否 | 字节数，用于进度条 |
| `minMacOSVersion` / `minAndroidSdk` | 否 | 仅作展示 / 以后过滤 |

模板：[`docs/release/latest-macos.json.example`](release/latest-macos.json.example)、[`docs/release/latest-android.json.example`](release/latest-android.json.example)。

客户端用 `version` + `buildNumber` 和本机比较；清单版本不高于本机则视为已是最新。未上传的平台清单返回 404 也视为无更新。

## 发版步骤

1. 把 `pubspec.yaml` 的 `version` 调到新版本，例如 `1.0.23+1`。
2. 打旁加载包：

```bash
./build_all.sh android-apk macos
```

产物示例：

- `dist/shepaw-1.0.23-android-release.apk`
- `dist/shepaw-1.0.23-macos-release.tar.gz`

3. 生成清单（`--download-base` 必须是用户真能下到安装包的前缀）：

```bash
tool/write_update_manifest.sh \
  --download-base https://release.shepaw.com/download \
  --notes "修复更新安装"
```

写出：

- `dist/update/latest-android.json`
- `dist/update/latest-macos.json`

若走 GitHub Releases：

```bash
tool/write_update_manifest.sh \
  --download-base https://github.com/OWNER/REPO/releases/download/1.0.23 \
  --notes "修复更新安装"
```

4. 上传安装包，使 `downloadUrl` 能直接 GET 到文件（不要登录墙、不要 HTML 中间页）。
5. 上传清单到固定路径（覆盖即可）：

```text
https://release.shepaw.com/api/v1/latest-macos.json
https://release.shepaw.com/api/v1/latest-android.json
```

GitHub Releases 当托管时，可用 Cloudflare 或 nginx 把上述路径反代到 Release 资产；或把 JSON 放到 Pages / R2 / 任意静态站，只要 URL 与客户端一致。

6. 用**旧版本** App 验证：

- 设置 → 检查更新，应看到新版本
- macOS：下载完成后系统会 `open` 安装包；当前产物是 `.tar.gz`，解压后把 `ShePaw.app` 拖到「应用程序」
- Android：允许「安装未知应用」后覆盖安装；须用**同一签名**的 APK，聊天数据才会保留

## 托管最小布局

```text
release.shepaw.com
  /api/v1/latest-macos.json
  /api/v1/latest-android.json
  /download/shepaw-1.0.23-macos-release.tar.gz
  /download/shepaw-1.0.23-android-release.apk
```

本地试可以用任意静态服务器，并在设置里把更新域名改成该源（含 `http://127.0.0.1:端口`）。

## 旧客户端（仍请求 `/api/v1/check-update`）

本仓库里新的客户端改查 `latest-{platform}.json`。已经装在用户机器上的旧版仍请求：

```text
GET /api/v1/check-update?platform=macos&currentVersion=1.0.22&buildNumber=1
```

要让旧版也能发现这次更新，用一层极薄的反代即可，不必写业务后端。nginx 示例：

```nginx
location = /api/v1/check-update {
  if ($arg_platform = macos)   { rewrite ^ /api/v1/latest-macos.json last; }
  if ($arg_platform = android) { rewrite ^ /api/v1/latest-android.json last; }
  return 404;
}
```

没有这层反代时：用户需要**手动装一次**带新检查路径的版本，之后才能自动收到后续更新。

## 不要用这条路径的情况

- **iOS**：系统不允许应用自己换 IPA。清单里的 `downloadUrl` 只能指向 TestFlight / App Store。
- **Google Play 上架包**：不要再用自建 APK 覆盖；应改走 Play 应用内更新。
- **改过签名的 Android 包**：不能覆盖安装，用户只能卸了重装，本地数据会丢。

## 相关代码

- 检查：`lib/services/update_service.dart`
- 下载 / 安装：`lib/services/update_notification_service.dart`
- 校验：`lib/services/update_checksum.dart`
- 构建：`BUILD_GUIDE.md`
