# ShePaw - 多平台构建指南

用仓库根目录的 `build_all.sh` 按平台打 release / debug 包，产物默认进 `dist/`。

## 快速开始

```bash
chmod +x build_all.sh

# 本机可构建的全部平台
./build_all.sh

# 指定平台（可多选）
./build_all.sh android
./build_all.sh macos web
./build_all.sh ios --debug
./build_all.sh android-apk --clean --out releases
```

查看全部参数：

```bash
./build_all.sh --help
```

## 支持的平台

| 参数 | 产物 | 说明 |
|------|------|------|
| `android` | APK +（有签名时）AAB | 等价于 `android-apk` + `android-aab` |
| `android-apk` | `shepaw-<ver>-android-*.apk` | debug / release |
| `android-aab` | `shepaw-<ver>-android-release.aab` | 需要 `android/key.properties` |
| `ios` | `shepaw-<ver>-ios-*.tar.gz` | 仅 macOS；`--no-codesign`，真机需 Xcode 签名 |
| `macos` | `.tar.gz` + 解压后的 `ShePaw.app` | 仅 macOS |
| `web` | `web/` + `.tar.gz` | 任意主机 |
| `all` | android + ios + macos + web | 默认；本机不支持的会跳过 |
| `windows` | 见下方 | **请用 `build_windows.ps1`，不要依赖 `build_all.sh`** |

### 关于 Windows

Flutter **不支持**从 macOS / Linux 交叉编译 Windows 桌面包。请在 **Windows** 上使用专用脚本：

```powershell
# 首次：生成 windows/ 工程
.\build_windows.ps1 -Init

# 正式包
.\build_windows.ps1

# 调试包 / 清理后构建
.\build_windows.ps1 -Mode debug
.\build_windows.ps1 -Clean -Out releases
```

或用 cmd 包装器：`build_windows.bat`

要求：Flutter 在 PATH 中；Visual Studio 安装「使用 C++ 的桌面开发」工作负载。

产物示例：`dist/shepaw-<ver>-windows-release.zip` 与解压目录 `dist/ShePaw/`。

日常在 Mac 上发包继续用 `./build_all.sh`（`macos` / `android` / `ios` / `web`）即可。

版本号从 `pubspec.yaml` 的 `version:` 自动读取。

## 常用选项

| 选项 | 含义 |
|------|------|
| `--release` | 正式包（默认） |
| `--debug` | 调试包 |
| `--clean` | 构建前 `flutter clean` |
| `--skip-pub-get` | 跳过 `flutter pub get` |
| `--out <dir>` | 产物目录（默认 `dist`） |

## Android 签名

**推荐**：把密钥放在 `data/`（不进 git），用本地脚本发包：

```bash
cp data/key.properties.example data/key.properties   # 已有可跳过
# 编辑 data/key.properties，并把 .jks 放到 data/
./data/build.sh android
```

详见 [data/README.md](data/README.md)。

兼容旧路径：`android/key.properties`（已 gitignore）。Gradle **优先**读 `data/key.properties`。

## 环境要求

- 全局：Flutter SDK（`flutter doctor` 通过）
- Android：Android SDK
- iOS / macOS：macOS + Xcode
- Windows：在 Windows 上跑 `build_windows.ps1`（可加 `-Init` 生成 `windows/`）

## 产物示例

```
dist/
  shepaw-1.0.17-android-release.apk
  shepaw-1.0.17-android-release.aab
  shepaw-1.0.17-macos-release.tar.gz
  ShePaw.app/
  shepaw-1.0.17-web-release.tar.gz
  web/
  build-report-YYYYMMDD-HHMMSS.txt
```

## 故障排除

1. **Flutter 找不到** — 把 Flutter 加入 PATH，再跑 `flutter doctor`
2. **Android 签名失败** — 检查 `android/key.properties` 与 `.jks` 路径
3. **iOS/macOS 跳过** — 必须在 macOS 上跑；确认已装 Xcode
4. **Windows 失败** — 在 Windows 上用 `.\build_windows.ps1`；缺 `windows/` 时加 `-Init`；确认 Visual Studio C++ 桌面工作负载

## 与旧脚本的关系

- `build_all.sh`：macOS/Linux 上构建 android / ios / macos / web
- `build_windows.ps1` / `build_windows.bat`：仅 Windows 桌面包
- `build_test.sh`：快速冒烟（Web + Android debug），不替代正式发包

## 许可证

构建脚本与本文档随项目采用 MIT 许可证。
