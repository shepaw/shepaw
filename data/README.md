# data/ — 本地构建与签名材料

本目录用于**本机发包**：密钥与 keystore 放这里，默认不进 git。

## 安全提醒（上线前必读）

历史上 `android/key.properties` 曾提交进版本库，其中的签名密码视为已泄露。正式发布前请：

1. **轮换** release keystore 密码（或生成新的 `.jks`）
2. 只把新密码写在本目录的 `key.properties`（已被 gitignore）
3. 不要把 `key.properties` / `*.jks` 再提交到 git

## 一次配置

1. 复制示例并填入真实密码：

```bash
cp data/key.properties.example data/key.properties
# 编辑 data/key.properties
```

2. 把 `.jks` 放到 `data/`（与 `storeFile=` 文件名一致），例如：

```bash
cp android/app/shepaw-release.jks data/shepaw-release.jks
# 或: ln -s ../android/app/shepaw-release.jks data/shepaw-release.jks
```

3. 构建：

```bash
./data/build.sh              # 本机可构建的全部平台
./data/build_all.sh android  # 同上（别名）
./data/build.sh macos
./data/build.sh android --debug
```

### Apple 签名（可选）

本机若没有 Apple Development Team，iOS 会打**未签名**包（可用 Xcode 再签）。

若要自动签名，复制并填写 Team ID：

```bash
cp data/apple.properties.example data/apple.properties
# DEVELOPMENT_TEAM=XXXXXXXXXX
```

macOS Release 会用钥匙串里的 `Developer ID Application`（需本机已导入对应证书和私钥）。

公证（notarytool）用 App Store Connect API 密钥，配一次即可：

```bash
# 1. https://appstoreconnect.apple.com/access/integrations/api
#    生成 API Key，下载 AuthKey_*.p8 到 data/apple/，Issuer ID 写入 apple.properties
# 2. 入库到钥匙串
./data/setup_notarytool.sh
```

之后 `./build_all.sh macos` 会在 Developer ID 签名后自动 submit + stapler。

Windows 桌面请在 Windows 上运行：`.\data\build_windows.ps1`

## Git 忽略规则

已忽略：`data/key.properties`、`data/*.jks`、`data/out/` 等密钥与产物。  
可提交：`data/build.sh`、`data/key.properties.example`、本 README。
