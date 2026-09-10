---
name: rebuild-all-platforms
description: 重新构建 ShePaw 全部平台产物（Android APK/AAB + iOS + macOS）并输出到 dist/。当用户说「重新构建全部平台」「重新出包」「跑 build_all」「让 dist 追上 HEAD」「产物过期了」时使用。
---

# 重新构建全部平台

跑 `./build_all.sh`，把 `dist/` 里的四平台产物刷新到当前 HEAD。

`all`（无参数默认）= `android-apk android-aab ios macos`，release 模式，产物落 `dist/`。
脚本 `set -euo pipefail`，每个 target 单独捕获退出码，最后写 `dist/build-report-<stamp>.txt` 并以失败数作为退出码。

## 0. 先对齐三个决策（用户已表态就直接执行，别重复问）

| 决策 | 推荐默认 | 备选 |
|---|---|---|
| 版本号 | 保持 `pubspec.yaml` 现值，原地覆盖 dist | 先 bump 再构建，产物并存可对比 |
| `--clean` | 不加（增量） | 加，彻底重来；增量出现诡异链接错误时回退到这条 |
| 构建前质量门 | 直接构建 | 先跑 `flutter analyze && flutter test --exclude-tags=needs-plugins`（CI 口径） |

判断「原地覆盖是否安全」：看该版本是否已打 tag。未打 tag = 未发布，覆盖合理。

## 1. 预检（30 秒，别省）

```bash
git status --short                      # 必须干净，否则产物混入未提交改动
grep -m1 '^version:' pubspec.yaml
test -f data/apple.properties && echo "Apple 签名 OK" || echo "无 Apple 签名 → iOS/macOS 走未签名路径"
test -f data/key.properties && test -f android/app/shepaw-release.jks && echo "Android 签名 OK" || echo "Android 签名缺失 → APK/AAB 会失败"
df -h . | tail -1                       # 需要几十 GB
```

Apple 签名缺失不是错误，脚本会走 `CODE_SIGNING_ALLOWED=NO` 并打印 warn。要在预检阶段就告诉用户「这两个产物未签名，不能装真机/上 TestFlight」。

## 2. 执行

**必须后台跑** —— 超单次 Bash 调用 10 分钟上限。实测（2026-09-11，增量、热缓存、无 `--clean`）：**06:44:21 → 06:49:56，约 5 分 35 秒**。冷缓存或 `--clean` 会明显更久。

```bash
./build_all.sh > /tmp/buildall-$(date +%Y%m%d-%H%M%S).log 2>&1
```

用 `run_in_background: true` 启动，等完成通知，再读日志尾部。
启动后花 10 秒确认日志开头是 `[INFO] Targets: android-apk android-aab ios macos`，证明没死在参数解析。

> ⚠️ **别在命令末尾追加 `; echo "EXIT=$?"` 来抓退出码。** 后台任务上报的是整条命令的退出码，`echo` 永远返回 0，会把真实失败吞掉 —— 报 `completed (0)` 而实际脚本退出码非 0。要么让 `./build_all.sh` 作为唯一命令、由后台任务退出码直接反映，要么把 `$?` 写进日志再读。同样注意：主动 `pkill` 调试实例会把这个后台任务标记成 `failed (144)`，那是信号不是构建失败。

## 3. 验证

```bash
log=$(ls -t /tmp/buildall-*.log | head -1)
grep -n 'Done\. Succeeded' "$log"       # 期望 [INFO] Done. Succeeded: android-apk android-aab ios macos
grep -n 'Target failed' "$log"          # 期望无输出
grep -niE '\[WARN\]|\[ERROR\]' "$log"   # 逐条判断，预期只有 iOS 未签名一条 WARN
cat dist/build-report-<stamp>.txt       # 核对 targets: 行
ls -lh dist/                            # 四个产物 mtime = 本次构建时间
du -sh dist/ShePaw.app                  # 实测 83M（脚本兜底阈值是 1000KB，防的是空壳）
```

> ⚠️ **别用 `tail` 找 `Succeeded` 行** —— 脚本会在它之后打印 dist 清单，`tail` 抓到的是文件列表。用 `grep`。

脚本已内置 iOS `Runner.app < 1000 KB` 的兜底校验。也可手工核对 tar 内 `Runner.app/Runner` 二进制（实测 25.7 MB）。

**功能冒烟**：`open dist/ShePaw.app` 起 macOS 版。Android 实机用 `adb install -r dist/shepaw-*-android-release.apk`。

大版本上线时，冒烟要覆盖本次新发的功能点 —— 先 `git log --oneline <上次构建commit>..HEAD` 看这轮进了什么。

**验证新功能时能拿到多少实证（以本机 Agent Hub 自动接入为例）**：
- ✅ 能做：`curl -s http://127.0.0.1:4000/api/health` 确认返回 `{"ok":true,"authRequired":false}` —— 这正是 `local_agent_hub_service.dart` 判定「检测成功、可接入」的条件；确认 app 进程存活
- ❌ 做不到：**提示条是否真的渲染出来，GUI 看不见，必须让用户目视确认**。release 版 `print` 走 stdout，`open` 启动的 GUI app 不进 unified log（`log show` 抓不到）；hub 侧 stdout 也非文件，无请求日志可查
- 直接跑二进制抓 stdout 只会有引擎噪声（`desktop_multi_window` 通道早于引擎就绪等），没有应用层 hub 日志

别把「链路是活的」说成「功能已验证」，最后一步交回用户。

## 4. 回滚

**dist 产物未进 git，覆盖前无备份。** 需要旧版只能 `git checkout <旧 commit>` 重跑脚本，无法从 git 恢复大文件。

## 已知坑

- **别并发跑另一个 flutter build** —— 脚本注释点名了并发导致 Xcode build DB 锁。
- **iOS 未签名路径会 `rm -rf build/ios/DerivedData`** 从头编译，这是最慢的一段，别以为卡死了。
- **macOS 构建前清 `build/macos/Build/Intermediates.noindex/XCBuildData`** —— 脚本内置的陈旧锁规避，正常行为。
- **APK ~123 MB 偏大是现状**，不是本次引入的问题。
- **Windows 无法从 macOS 交叉编译**，脚本 `all` 刻意排除 windows，显式传 `windows` 在非 Windows 主机上直接返回 1。要 Windows 包得上 Windows 机器跑 `.\build_windows.ps1`（首次加 `-Init`，需 VS「使用 C++ 的桌面开发」工作负载）。

## 环境

- Flutter：`/Users/edenzou/sdk/flutter/bin/flutter`
- 签名模板：`data/apple.properties.example`、`data/key.properties.example`
