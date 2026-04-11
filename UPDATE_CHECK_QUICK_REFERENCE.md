# 📱 App 更新检查频率 - 快速参考表

## ⚡ 一句话总结

**App 成功检查后会等 6 小时才再检查，失败后会等 1 小时重试。**

---

## 📊 快速对比表

| 场景 | 时间间隔 | 备注 |
|------|---------|------|
| ✅ 成功/无更新后 | **6 小时** | 冷却期内的重复启动不发请求 |
| ❌ 网络失败后 | **1 小时** | 避免频繁对无法连接的服务器请求 |
| ⏱️ 单次请求超时 | **10 秒** | 超过此时间视为超时，计入失败 |
| 🔄 用户手动检查 | **立即** | 绕过冷却，force=true 直接请求 |

---

## 🎯 场景速查

### 场景 A: 用户早上 8:00 启动 App

| 时间 | 动作 | 结果 |
|------|------|------|
| 08:00 | 启动 App | 检查更新，无新版本，存储时间 |
| 08:30 | 关闭重启 | ✋ 冷却中（30分 < 6h），不检查，返回缓存 |
| 12:00 | 关闭重启 | ✋ 冷却中（4h < 6h），不检查，返回缓存 |
| 14:00 | 关闭重启 | ✅ 冷却过期（6h），发起新检查 |
| 14:00 | 手动检查 | ✅ 立即检查（force=true），发起新请求 |

### 场景 B: 网络不稳定的用户早上 8:00 启动 App

| 时间 | 动作 | 结果 |
|------|------|------|
| 08:00 | 启动 App | ❌ 网络失败，存储时间 = 08:00 - 6h + 1h = 02:00 |
| 09:00 | 关闭重启 | ✋ elapsed = 7h，但因为存储时间是 02:00，所以需要对比的是从 02:00 开始，即到 08:00 需要 6h，此时不到 6h，等等... |
| 09:00 | (重新计算) | elapsed = 09:00 - 02:00 = 7h >= 6h，✅ 发起新请求 |

**简化理解**: 失败后 1 小时内不会重试，1 小时后才会再试一次

---

## 📂 文件位置速查

| 需要修改什么 | 找哪个文件 | 第几行 |
|-------------|---------|--------|
| 成功检查间隔 | `lib/services/update_service.dart` | 第 68 行 |
| 失败重试间隔 | `lib/services/update_service.dart` | 第 71 行 |
| 请求超时时间 | `lib/services/update_service.dart` | 第 74 行 |
| 检查入口逻辑 | `lib/screens/adaptive_home_screen.dart` | 第 22-46 行 |
| 数据模型 | `lib/models/update_model.dart` | 全文 |

---

## 🔧 常见修改

### 改成 12 小时检查一次

```dart
// 文件: lib/services/update_service.dart
// 第 68 行，改这行：
static const Duration _minCheckInterval = Duration(hours: 12);  // 从 6 改成 12
```

### 改成失败后立即重试（不等）

```dart
// 文件: lib/services/update_service.dart
// 第 71 行，改这行：
static const Duration _errorRetryInterval = Duration.zero;  // 从 1 小时改成 0
```

### 改成 30 秒超时

```dart
// 文件: lib/services/update_service.dart
// 第 74 行，改这行：
static const Duration _requestTimeout = Duration(seconds: 30);  // 从 10 改成 30
```

---

## 🔑 代码位置速查

### 查看冷却是否被应用

**搜索**: `if (elapsed < _minCheckInterval)`

**在文件**: `lib/services/update_service.dart` 第 101 行

```dart
if (elapsed < _minCheckInterval) {  // 检查冷却是否过期
  // 冷却中，返回缓存
  return UpdateCheckResult(...);
}
```

### 查看失败时的冷却设置

**搜索**: `now.subtract(_minCheckInterval).add(_errorRetryInterval)`

**在文件**: `lib/services/update_service.dart` 第 207, 222, 236, 252 行

```dart
await _saveLastCheckTime(
  now.subtract(_minCheckInterval).add(_errorRetryInterval),  // 计算冷却时间
);
```

### 查看什么时候会跳过冷却

**搜索**: `force = true`

**在文件**: `lib/services/update_service.dart` 第 92 行

```dart
Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
  if (!force) {
    // force = false 时应用冷却
  }
  // force = true 时跳过冷却逻辑，直接发起请求
}
```

---

## 📡 API 信息速查

| 项目 | 值 |
|------|-----|
| 基础 URL | `http://release.shepaw.com` |
| 端点 | `/api/v1/check-update` |
| 请求方法 | `GET` |
| 响应成功 | `200 OK` (返回 JSON) 或 `204 No Content` (无更新) |
| 响应失败 | `4xx`, `5xx`, 超时, 网络错误 |

### 示例请求 URL

```
http://release.shepaw.com/api/v1/check-update?platform=ios&currentVersion=1.0.0&buildNumber=5
```

---

## 💾 SharedPreferences 键速查

| 键 | 用途 | 值类型 |
|----|------|--------|
| `update_last_check_time` | 最后一次检查的时间 | int (毫秒时间戳) |
| `update_cached_info` | 缓存的更新信息 | String (JSON) |
| `update_skipped_version` | 用户跳过的版本号 | String |
| `update_pending_install_path` | 待安装的文件路径 | String |
| `update_pending_install_version` | 待安装的版本号 | String |
| `update_declined_version` | 用户永久拒绝的版本 | String |

---

## 🧪 测试方法

### 测试冷却是否生效

1. 启动 App → 触发检查
2. 立即重启 → 验证返回缓存（不发起新请求）
3. 查看日志: `Skipping update check (cooldown: Xmin elapsed)`

### 测试失败冷却

1. 模拟网络不可达（关闭 Wi-Fi/飞行模式）
2. 启动 App → 检查失败，存储冷却时间
3. 立即重启 → 验证仍在冷却中
4. 等 1 小时后重启 → 验证再次发起请求

### 测试手动检查绕过冷却

1. 启动 App → 触发检查
2. 设置界面点击"检查更新" → 应该立即发起请求（不受 6 小时限制）
3. 查看日志: 应该看到新的 HTTP 请求

---

## 📈 日志关键词

| 日志内容 | 含义 |
|---------|------|
| `Returning cached update info` | 冷却中，返回缓存 |
| `Skipping update check` | 冷却中，跳过检查 |
| `Checking for updates` | 开始发起新检查 |
| `No update available` | 检查成功，无新版本 |
| `Update available` | 检查成功，有新版本 |
| `Network unavailable` | 网络失败 |
| `Update check timed out` | 请求超时 |

---

## ✅ 检查清单

- [ ] 修改了 `_minCheckInterval` 吗？
- [ ] 修改了 `_errorRetryInterval` 吗？
- [ ] 修改了 `_requestTimeout` 吗？
- [ ] 运行了 `flutter pub get`？
- [ ] 重新构建了 App？
- [ ] 用新的 build number 测试（避免缓存版本）？
- [ ] 查看了日志验证修改生效？

---

## 🎓 理解冷却的关键公式

**冷却判断**:
```
当前时间 - 上次检查时间 < 冷却时间
```

**失败冷却的时间计算**:
```
存储时间 = 当前时间 - 6小时 + 1小时 = 当前时间 - 5小时
下次检查时间 = 存储时间 + 6小时 = 当前时间 + 1小时
```

**意思**: 失败后最多等 1 小时再试

---

## 🚀 快速导航

- 🔍 **想找配置值？** → `lib/services/update_service.dart` 第 67-74 行
- 🎯 **想看检查逻辑？** → `lib/services/update_service.dart` 第 92-261 行
- 📱 **想看启动流程？** → `lib/screens/adaptive_home_screen.dart` 第 22-46 行
- 🔔 **想看通知流程？** → `lib/services/update_notification_service.dart` 全文
- 📊 **想看数据模型？** → `lib/models/update_model.dart` 全文

