# Flutter 应用更新检查频率/间隔设置总结

## 📋 核心文件

### 1. **lib/models/update_model.dart**
定义了更新相关的数据模型，包括：
- `VersionInfo`: 版本号信息
- `UpdateInfo`: 更新信息（从远程服务器获取）
- `UpdateCheckResult`: 更新检查结果
- `DownloadProgress`: 下载进度信息

---

## 🔍 更新检查频率/间隔配置

### **文件位置**: `lib/services/update_service.dart`

### **关键配置参数**

| 配置项 | 值 | 说明 |
|------|-----|-----|
| **成功/无更新冷却** | **6 小时** | 检查成功或无更新后的最小检查间隔 |
| **失败冷却** | **1 小时** | 网络错误或服务不可用后的最小检查间隔 |
| **HTTP 超时** | **10 秒** | 单次请求的超时时间 |

### **源代码片段**

```dart
/// 正常冷却间隔：成功或无更新后 6 小时内不重复请求
static const Duration _minCheckInterval = Duration(hours: 6);

/// 失败冷却间隔：网络错误或服务不可用后 1 小时内不重试，
/// 避免每次启动都尝试不可达的服务
static const Duration _errorRetryInterval = Duration(hours: 1);

/// HTTP 请求超时时间
static const Duration _requestTimeout = Duration(seconds: 10);
```

---

## 🔄 更新检查流程

### **流程概述**

1. **启动时检查**（通过 `lib/screens/adaptive_home_screen.dart`）
   - App 启动后在第一帧渲染完成时自动检查
   - 先检查是否有待安装的更新包（之前下载但用户选择"稍后"）
   - 再检查是否有新版本

2. **冷却机制**（在 `UpdateService.checkForUpdate()` 中实现）
   ```dart
   Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
     final now = DateTime.now();
     
     if (!force) {
       // 检查上次检查时间，避免频繁请求
       final lastCheck = await _getLastCheckTime();
       if (lastCheck != null) {
         final elapsed = now.difference(lastCheck);
         // 冷却时间内，直接返回缓存结果（无论成功/失败）
         if (elapsed < _minCheckInterval) {
           // 返回缓存结果...
         }
       }
     }
     // ... 发起检查请求
   }
   ```

3. **手动检查**
   - 用户可以手动触发检查（通过设置界面）
   - 传入 `force: true` 绕过冷却，立即发起请求

---

## 📊 更新检查的错误处理

| 错误类型 | 冷却时间 | 说明 |
|---------|---------|-----|
| 成功/无更新 | 6 小时 | 正常情况，等待 6 小时后再次检查 |
| 网络不可达 | 1 小时 | SocketException（DNS失败、无网络等） |
| 请求超时 | 1 小时 | 超过 10 秒无响应 |
| HTTP 4xx/5xx | 1 小时 | 服务端错误 |
| 其他异常 | 1 小时 | JSON 解析错误等 |

---

## 🎯 关键行为

### **缓存机制**
- **SharedPreferences 键**:
  - `update_last_check_time`: 最后一次检查的时间戳
  - `update_cached_info`: 缓存的更新信息（JSON）
  - `update_skipped_version`: 用户跳过的版本号
  
### **冷却时间的应用**
```dart
// 成功/无更新：使用正常冷却（6小时）
await _saveLastCheckTime(now);  // now 距离上次检查已超过 6 小时时会再次检查

// 失败情况：使用失败冷却（1小时）
await _saveLastCheckTime(
  now.subtract(_minCheckInterval).add(_errorRetryInterval)
);
// 相当于存储: now - 6h + 1h = now - 5h
// 这样 1 小时后 (now + 1h) - (now - 5h) = 6h，就会重新触发检查
```

---

## 🌐 API 端点

**API 地址**: `http://release.shepaw.com/api/v1/check-update`

**请求参数**:
- `platform`: "ios" | "android" | "macos" | "windows" | "linux"
- `currentVersion`: 当前版本号（格式 "1.2.3"）
- `buildNumber`: 当前构建号（格式 "4"）

**响应**:
- `200 OK`: 返回 JSON，包含新版本信息
- `204 No Content`: 没有可用更新

---

## 📝 文件路径总结

| 文件 | 用途 |
|-----|------|
| `lib/models/update_model.dart` | 更新相关的数据模型 |
| `lib/services/update_service.dart` | **核心服务**：检查频率/冷却配置在此 |
| `lib/services/update_notification_service.dart` | 更新通知和下载流程编排 |
| `lib/screens/adaptive_home_screen.dart` | 启动时的更新检查入口 |
| `lib/widgets/update_download_dialog.dart` | 更新对话框 UI |

---

## 🔧 修改频率的方法

要修改更新检查的频率，编辑 `lib/services/update_service.dart` 中的这些常量：

```dart
// 改这个值可以修改成功后的检查间隔
// 例如改为 Duration(hours: 24) 表示 24 小时检查一次
static const Duration _minCheckInterval = Duration(hours: 6);

// 改这个值可以修改失败后的重试间隔
// 例如改为 Duration(minutes: 30) 表示 30 分钟重试一次
static const Duration _errorRetryInterval = Duration(hours: 1);

// 改这个值可以修改请求超时时间
// 例如改为 Duration(seconds: 15) 表示 15 秒超时
static const Duration _requestTimeout = Duration(seconds: 10);
```

---

## 📌 总结

✅ **成功/无更新**: 每 **6 小时** 检查一次
✅ **失败重试**: 每 **1 小时** 重试一次  
✅ **请求超时**: **10 秒**  
✅ **检查触发**: 应用启动时自动检查（受冷却限制）  
✅ **手动检查**: 用户可通过设置界面手动触发（绕过冷却）
