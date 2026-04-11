# 🔍 Flutter 项目更新检查频率 - 完整调查报告

## 📌 执行摘要

本项目的 **App 更新检查频率设置如下**：

| 配置 | 值 | 文件位置 |
|------|-----|---------|
| 🕐 成功/无更新冷却 | **6 小时** | `lib/services/update_service.dart:68` |
| 🔄 失败重试冷却 | **1 小时** | `lib/services/update_service.dart:71` |
| ⏱️ HTTP 请求超时 | **10 秒** | `lib/services/update_service.dart:74` |

---

## 🎯 核心发现

### 1. 检查频率是通过冷却机制实现的

**原理**: 每次检查后，App 会记录检查时间。下次检查时，会对比距上次检查的时间：
- 如果 **< 6 小时**：直接返回缓存，不发送新请求
- 如果 **≥ 6 小时**：发起新请求

### 2. 双重冷却机制

**成功冷却**（6 小时）:
```dart
static const Duration _minCheckInterval = Duration(hours: 6);
```

**失败冷却**（1 小时）:
```dart
static const Duration _errorRetryInterval = Duration(hours: 1);
```

失败时的存储公式:
```
存储时间 = 当前时间 - 6小时 + 1小时 = 当前时间 - 5小时
结果: 1 小时后才会再次触发检查
```

### 3. 检查在应用启动时自动触发

**位置**: `lib/screens/adaptive_home_screen.dart`

**流程**:
1. App 启动完毕后，在第一帧渲染完成时自动检查
2. 先检查是否有待安装的包（之前下载但用户选择"稍后"）
3. 再进行新版本检查（受 6 小时冷却限制）

### 4. 用户可以手动触发检查

**方式**: 通过设置界面的"检查更新"按钮

**特点**: 
- 使用 `force: true` 参数
- 绕过 6 小时冷却，立即发起请求

---

## 📁 相关文件清单

### 1. **lib/models/update_model.dart** (240 行)
**用途**: 定义更新相关的数据模型

**关键类**:
- `VersionInfo`: 版本号解析和比对
- `UpdateInfo`: 更新信息（服务器返回）
- `UpdateCheckResult`: 检查结果
- `DownloadProgress`: 下载进度

### 2. **lib/services/update_service.dart** (336 行) ⭐
**用途**: 核心更新检查服务，包含所有配置和逻辑

**关键常量**:
- `_minCheckInterval = Duration(hours: 6)` (第 68 行)
- `_errorRetryInterval = Duration(hours: 1)` (第 71 行)
- `_requestTimeout = Duration(seconds: 10)` (第 74 行)

**关键方法**:
- `checkForUpdate({bool force})`: 执行检查，包含冷却逻辑
- `_getLastCheckTime()`: 从本地存储读取最后检查时间
- `_saveLastCheckTime()`: 保存检查时间
- `_getCachedUpdateInfo()`: 读取缓存的更新信息

**错误处理**:
- SocketException (网络不可达) → 1 小时冷却
- TimeoutException (请求超时) → 1 小时冷却
- HTTP 4xx/5xx → 1 小时冷却
- JSON 解析错误 → 1 小时冷却

### 3. **lib/services/update_notification_service.dart** (545 行)
**用途**: 更新通知和下载流程编排

**功能**:
- 检测到新版本时发送系统通知
- 处理用户点击通知的响应
- 后台下载更新包
- 显示"已就绪"通知
- 调用平台安装程序

**关键 SharedPreferences 键**:
- `update_pending_install_path`: 待安装文件路径
- `update_pending_install_version`: 待安装版本号
- `update_declined_version`: 用户永久拒绝的版本

### 4. **lib/screens/adaptive_home_screen.dart** (55 行)
**用途**: App 主屏幕，也是更新检查的入口

**关键代码**:
```dart
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (mounted) {
      await UpdateNotificationService().checkAndInstallPending(context);
    }
    if (mounted) {
      _checkForUpdates();
    }
  });
}
```

---

## 🔐 本地数据存储

使用 `SharedPreferences` 存储以下信息：

| 键 | 类型 | 用途 |
|----|------|------|
| `update_last_check_time` | int | 最后检查的时间戳（毫秒） |
| `update_cached_info` | String | 缓存的更新信息（JSON 格式） |
| `update_skipped_version` | String | 用户跳过的版本号 |
| `update_pending_install_path` | String | 待安装文件的绝对路径 |
| `update_pending_install_version` | String | 待安装的版本号 |
| `update_declined_version` | String | 用户永久拒绝的版本号 |

---

## 🌐 API 接口信息

**端点**: `http://release.shepaw.com/api/v1/check-update`

**请求参数**:
```
GET /api/v1/check-update?platform=ios&currentVersion=1.0.0&buildNumber=5
```

| 参数 | 值 | 说明 |
|------|-----|------|
| `platform` | ios/android/macos/windows/linux | 平台标识 |
| `currentVersion` | 1.0.0 | 当前应用版本 |
| `buildNumber` | 5 | 当前构建号 |

**响应**:
- **200 OK**: 返回 JSON，包含新版本信息
- **204 No Content**: 无可用更新
- **其他**: 服务端错误

**响应 JSON 示例** (200 OK):
```json
{
  "version": "1.2.3",
  "buildNumber": "5",
  "description": "更新内容...",
  "isMandatory": false,
  "releaseDate": "2024-03-24T10:30:00Z",
  "downloadUrl": "https://release.shepaw.com/download/...",
  "fileSize": 12345678,
  "checksum": "sha256:abcdef...",
  "minIosVersion": "14.0",
  "minAndroidSdk": 21,
  "minMacOSVersion": "11.0",
  "minWindowsVersion": "10.0"
}
```

---

## 🧪 实际行为示例

### 示例 1: 正常工作流程

```
时间     | 动作              | 日志                           | 存储的检查时间
---------|------------------|-------------------------------|---------------
08:00    | App 启动          | "Checking for updates"        | 08:00
         |                  | "No update available"         |
08:30    | 用户重启 App      | "Skipping update check"       | 08:00 (无变化)
         |                  | "(cooldown: 30min elapsed)"   |
14:00    | 用户重启 App      | "Checking for updates"        | 14:00
         |                  | "No update available"         |
14:00    | 用户手动检查      | "Checking for updates"        | 14:00
         |                  | (立即执行，force=true)        |
```

### 示例 2: 网络失败工作流程

```
时间     | 动作              | 日志                           | 存储的检查时间
---------|------------------|-------------------------------|---------------
08:00    | App 启动          | "Network unavailable"         | 02:00*
         |                  | "(使用失败冷却)"              | (*08:00-6h+1h)
08:30    | 用户重启 App      | "Skipping update check"       | 02:00 (无变化)
         |                  | "(cooldown: Xmin elapsed)"    |
09:00    | 用户重启 App      | "Checking for updates"        | 09:00
         |                  | (elapsed ≈ 7h, 超过 6h)      |
```

---

## 🔧 修改频率的步骤

### 步骤 1: 打开配置文件
```bash
open lib/services/update_service.dart
```

### 步骤 2: 定位到第 67-74 行
```dart
/// 正常冷却间隔：成功或无更新后 6 小时内不重复请求
static const Duration _minCheckInterval = Duration(hours: 6);

/// 失败冷却间隔：网络错误或服务不可用后 1 小时内不重试
static const Duration _errorRetryInterval = Duration(hours: 1);

/// HTTP 请求超时时间
static const Duration _requestTimeout = Duration(seconds: 10);
```

### 步骤 3: 修改所需的常量
例如，改成 24 小时：
```dart
static const Duration _minCheckInterval = Duration(hours: 24);
```

### 步骤 4: 保存并重建
```bash
flutter pub get
flutter run
```

---

## 📊 冷却机制深度解析

### 成功检查的冷却逻辑

```dart
// 这是 update_service.dart 中的核心逻辑（第 95-120 行）
final lastCheck = await _getLastCheckTime();
if (lastCheck != null) {
  final elapsed = now.difference(lastCheck);
  if (elapsed < _minCheckInterval) {
    // 6 小时内，直接返回缓存
    final cached = await _getCachedUpdateInfo();
    if (cached != null) {
      return UpdateCheckResult(
        hasUpdate: true,
        updateInfo: cached,
        timestamp: lastCheck,
      );
    }
    return UpdateCheckResult(hasUpdate: false, timestamp: lastCheck);
  }
}
```

**时间轴**:
```
首次检查: 08:00  → 存储 08:00
再次检查: 08:30  → elapsed = 30min < 6h  → 返回缓存
再次检查: 12:00  → elapsed = 4h < 6h     → 返回缓存
再次检查: 14:00  → elapsed = 6h >= 6h    → 发起新请求
```

### 失败检查的冷却逻辑

```dart
// 第 207-209 行
await _saveLastCheckTime(
  now.subtract(_minCheckInterval).add(_errorRetryInterval),
);
// 等价于: now - 6h + 1h = now - 5h
```

**时间计算**:
```
失败时刻: 08:00
存储时间: 08:00 - 6h + 1h = 02:00
下次检查: 当 elapsed >= 6h 时
即: 09:00 - 02:00 = 7h >= 6h ✓ 可以重试
```

**简化理解**: 失败后 1 小时内会拒绝所有检查请求，1 小时后才允许重试。

---

## 🎯 使用场景

### 场景 1: 普通用户（网络正常）
- 首次启动: 检查更新 → 存储时间
- 之后 6 小时内多次启动: 返回缓存，不发送请求
- 6 小时后启动: 发起新检查
- 用户主动检查: 立即检查（绕过 6 小时限制）

**效果**: 既保证了检查的及时性，又避免频繁请求

### 场景 2: 网络不稳定用户
- 启动时网络失败: 存储冷却时间（只等 1 小时）
- 1 小时内重试: 拒绝，返回缓存
- 1 小时后重试: 发起新检查
- 用户主动检查: 立即检查

**效果**: 自动重试，但避免每次启动都尝试连接不可达的服务

### 场景 3: 国外用户（网络延迟高）
- 如果 10 秒内无响应: 视为超时，计入失败
- 失败后等 1 小时再试
- 如果需要更长超时，可修改 `_requestTimeout` 为 30 秒

**效果**: 保证超时检测的敏感度

---

## ✅ 验证清单

在修改更新频率后，建议检查以下项：

- [ ] 修改了正确的常量值
- [ ] 没有修改了其他文件
- [ ] 运行了 `flutter pub get`
- [ ] 完全清理并重建了 App (`flutter clean` 后 `flutter run`)
- [ ] 使用新的 build number 构建（避免 SharedPreferences 缓存）
- [ ] 在真机或模拟器上测试
- [ ] 查看日志验证冷却时间
- [ ] 测试了成功检查和失败检查两种情况
- [ ] 测试了手动检查（绕过冷却）

---

## 📚 相关文档

本项目已生成以下辅助文档：

1. **UPDATE_CHECK_FREQUENCY_SUMMARY.md** - 更新检查频率总结表
2. **UPDATE_CHECK_CODE_SNIPPETS.md** - 详细代码片段和解析
3. **UPDATE_CHECK_QUICK_REFERENCE.md** - 快速参考表和常见修改

---

## 🎓 关键概念总结

| 术语 | 解释 |
|------|------|
| **冷却 (Cooldown)** | 两次检查之间的最小间隔时间 |
| **成功冷却** | 检查成功（无论有无更新）后等待 6 小时 |
| **失败冷却** | 检查失败后等待 1 小时 |
| **缓存** | 上次检查的结果，冷却期内直接返回 |
| **Force 检查** | 跳过冷却，用户手动触发的检查 |
| **SharedPreferences** | 本地持久化存储（如 iOS 的 UserDefaults） |

---

## 📞 快速查询

**Q: 如何修改成每天检查一次？**
A: 将 `_minCheckInterval` 改为 `Duration(hours: 24)`

**Q: 如何在网络恢复后立即重试？**
A: 将 `_errorRetryInterval` 改为 `Duration.zero`

**Q: 如何增加请求超时时间？**
A: 将 `_requestTimeout` 改为 `Duration(seconds: 30)`

**Q: 冷却是存储在哪里的？**
A: SharedPreferences 中的 `update_last_check_time`

**Q: 用户手动检查是否受冷却限制？**
A: 不受，使用 `force: true` 绕过冷却

**Q: 无网络时是否会阻塞 App？**
A: 不会，检查在后台异步执行，超时设置为 10 秒

---

**生成时间**: 2026-04-10
**项目**: Shepaw Flutter App
**检查工具**: 代码分析 + Grep 搜索

