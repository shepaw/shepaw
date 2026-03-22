# ShePaw - 多平台构建指南

本文档说明如何使用构建脚本为 ShePaw 项目构建多个平台的应用包。

## 构建脚本

我们创建了一个名为 `build_all.sh` 的构建脚本，用于自动化构建多个平台的应用包。

### 支持的平台

1. **Android**
   - APK (debug 和 release)
   - App Bundle (AAB，需要签名配置)

2. **iOS**
   - iOS 应用（需要 macOS 和 Xcode）

3. **macOS**
   - macOS 桌面应用（需要 macOS）

4. **Web**
   - 现代浏览器 Web 应用

5. **Windows**
   - Windows 桌面应用（需要 Windows 构建支持）

## 快速开始

### 1. 确保环境准备就绪

构建前请确保：
- Flutter SDK 已安装并配置
- 对于 Android 构建：Android SDK 已安装
- 对于 iOS/macOS 构建：需要在 macOS 系统上，且 Xcode 已安装
- 对于 Windows 构建：需要在 Windows 系统或已启用 Windows 桌面构建支持

### 2. 运行构建脚本

```bash
# 给予执行权限（如果尚未执行）
chmod +x build_all.sh

# 运行构建脚本
./build_all.sh
```

### 3. 查看构建结果

构建完成后，所有构建产物将保存在 `dist/` 目录中：
- Android APK/AAB 文件
- macOS 应用压缩包
- Web 应用文件和压缩包
- Windows 应用压缩包
- 构建报告

## 详细说明

### Android 构建

#### 调试版本
调试版本 APK 不需要签名配置，可以直接构建。

#### 发布版本
发布版本 APK 和 App Bundle 需要签名配置：
1. 复制示例配置文件：`cp android/key.properties.example android/key.properties`
2. 编辑 `android/key.properties`，填入你的签名信息

### iOS 构建

iOS 构建需要在 macOS 系统上进行，并需要：
1. Xcode 已安装
2. Apple Developer 账户（用于代码签名）

构建的 iOS 应用需要手动进行代码签名才能在真机上运行。

### macOS 构建

macOS 构建需要在 macOS 系统上进行，构建产物为 `.app` 应用程序包。

### Web 构建

Web 构建可以在任何支持 Flutter 的系统上进行，构建产物为标准的 Web 文件（HTML、CSS、JS）。

### Windows 构建

Windows 构建：
- 在 Windows 系统上可以直接构建
- 在其他系统上需要启用 Windows 桌面构建支持：`flutter config --enable-windows-desktop`

## 构建选项

### 单独构建特定平台

如果你只需要构建特定平台，可以修改脚本或直接使用 Flutter 命令：

```bash
# 只构建 Android debug APK
flutter build apk --debug

# 只构建 Android release APK
flutter build apk --release

# 只构建 Android App Bundle
flutter build appbundle --release

# 只构建 iOS
flutter build ios --release

# 只构建 macOS
flutter build macos --release

# 只构建 Web
flutter build web --release

# 只构建 Windows
flutter build windows --release
```

### 自定义构建目录

默认构建目录为 `dist/`，如果需要修改，可以编辑脚本中的 `OUTPUT_DIR` 变量。

## 故障排除

### 常见问题

1. **Flutter 命令未找到**
   - 确保 Flutter SDK 已正确安装并添加到 PATH
   - 运行 `flutter doctor` 检查环境

2. **Android 签名失败**
   - 检查 `android/key.properties` 文件是否存在且配置正确
   - 确保签名文件路径正确

3. **iOS/macOS 构建失败**
   - 确保在 macOS 系统上运行
   - 检查 Xcode 是否已安装
   - 运行 `flutter doctor` 检查 iOS/macOS 环境

4. **Web 构建失败**
   - 确保 Chrome 或 Chromium 已安装（用于测试）
   - 检查网络连接

5. **Windows 构建失败**
   - 在非 Windows 系统上，确保已启用 Windows 桌面构建支持
   - 运行 `flutter config --enable-windows-desktop`

### 获取帮助

如果遇到问题：
1. 查看构建脚本输出的详细错误信息
2. 检查 `dist/` 目录中的构建报告
3. 运行 `flutter doctor -v` 检查环境配置
4. 查看 Flutter 官方文档

## 自动化构建

### CI/CD 集成

构建脚本可以集成到 CI/CD 流程中：

```yaml
# GitHub Actions 示例
name: Build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.x'
      - run: chmod +x build_all.sh
      - run: ./build_all.sh
      - uses: actions/upload-artifact@v3
        with:
          name: build-artifacts
          path: dist/
```

### 定时构建

可以使用 cron 任务进行定时构建。

## 版本管理

构建脚本会自动在构建报告中包含：
- 构建时间
- 项目版本
- Flutter 版本
- 构建平台列表
- 构建产物详情

## 更新日志

### v1.0.0 (2026-03-01)
- 初始版本：支持 Android、iOS、macOS、Web、Windows 多平台构建
- 包含详细的错误检查和报告功能
- 支持调试版和发布版构建

## 贡献

欢迎提交 Issue 和 Pull Request 来改进构建脚本。

## 许可证

本构建脚本和文档采用 MIT 许可证。