# Flutter 应用更新检查 - 详细代码片段

## 1. 核心配置 (lib/services/update_service.dart - 第 67-74 行)

```dart
/// 正常冷却间隔：成功或无更新后 6 小时内不重复请求
static const Duration _minCheckInterval = Duration(hours: 6);

/// 失败冷却间隔：网络错误或服务不可用后 1 小时内不重试，避免每次启动都尝试
static const Duration _errorRetryInterval = Duration(hours: 1);

/// HTTP 请求超时时间
static const Duration _requestTimeout = Duration(seconds: 10);
```

**含义**:
- `_minCheckInterval = 6 小时`: App 检查一次后，6 小时内不会重复检查
- `_errorRetryInterval = 1 小时`: 如果检查失败，1 小时后才会重新尝试
- `_requestTimeout = 10 秒`: 如果请求超过 10 秒没有响应，则视为超时

---

## 2. 检查逻辑核心 (lib/services/update_service.dart - 第 92-120 行)

```dart
/// 检查是否有更新可用
///
/// [force] 为 true 时忽略冷却时间，立即发起请求（用于用户手动检查）
Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
  final now = DateTime.now();

  if (!force) {
    // 检查上次检查时间，避免频繁请求
    final lastCheck = await _getLastCheckTime();
    if (lastCheck != null) {
      final elapsed = now.difference(lastCheck);
      // 冷却时间内，直接返回缓存结果（无论成功/失败）
      if (elapsed < _minCheckInterval) {
        final cached = await _getCachedUpdateInfo();
        if (cached != null) {
          _logger.debug(
            'Returning cached update info (cooldown: ${elapsed.inMinutes}min elapsed)',
            tag: 'UpdateService',
          );
          return UpdateCheckResult(
            hasUpdate: true,
            updateInfo: cached,
            timestamp: lastCheck,
          );
        }
        _logger.debug(
          'Skipping update check (cooldown: ${elapsed.inMinutes}min elapsed)',
          tag: 'UpdateService',
        );
        return UpdateCheckResult(hasUpdate: false, timestamp: lastCheck);
      }
    }
  }
  
  // ... 继续发起 HTTP 请求
}
```

**逻辑说明**:
1. 如果 `force = false`（自动检查），检查上次检查时间
2. 如果距上次检查不到 6 小时，直接返回缓存结果（不发送请求）
3. 如果超过 6 小时或 `force = true`，才会发起新的请求

---

## 3. 成功响应处理 (lib/services/update_service.dart - 第 147-154 行)

```dart
// 请求成功（无论有无更新），记录检查时间（使用正常冷却）
await _saveLastCheckTime(now);

if (response.statusCode == 204) {
  // 无可用更新
  await _clearCachedUpdateInfo();
  _logger.info('No update available', tag: 'UpdateService');
  return UpdateCheckResult(hasUpdate: false, timestamp: now);
}
```

**含义**:
- 每次成功请求都会存储当前时间
- 下次检查时会对比时间差，确保不超过 6 小时检查一次

---

## 4. 失败处理 - 网络不可达 (lib/services/update_service.dart - 第 215-229 行)

```dart
} on SocketException catch (e) {
  // 网络不可达（服务器不存在、DNS 解析失败、无网络等）
  _logger.warning(
    'Network unavailable while checking update: $e',
    tag: 'UpdateService',
  );
  // 使用失败冷却（1h），避免每次启动都尝试不可达的服务
  await _saveLastCheckTime(
    now.subtract(_minCheckInterval).add(_errorRetryInterval),
  );
  return UpdateCheckResult(
    hasUpdate: false,
    error: 'network_error',
    timestamp: now,
  );
}
```

**含义**:
- 计算公式: `now - 6h + 1h = now - 5h`
- 存储的时间点会比当前时间早 5 小时
- 这样 1 小时后，`elapsed = 6h`，就会触发下次检查

---

## 5. 失败处理 - 请求超时 (lib/services/update_service.dart - 第 230-243 行)

```dart
} on TimeoutException catch (e) {
  // 请求超时（服务器无响应）
  _logger.warning(
    'Update check timed out: $e',
    tag: 'UpdateService',
  );
  await _saveLastCheckTime(
    now.subtract(_minCheckInterval).add(_errorRetryInterval),
  );
  return UpdateCheckResult(
    hasUpdate: false,
    error: 'timeout',
    timestamp: now,
  );
}
```

**含义**:
- 和网络错误一样，也使用失败冷却（1 小时）
- 避免频繁对无响应的服务器发起请求

---

## 6. 启动时的检查入口 (lib/screens/adaptive_home_screen.dart - 第 22-35 行)

```dart
class _AdaptiveHomeScreenState extends State<AdaptiveHomeScreen> {
  @override
  void initState() {
    super.initState();
    // 延迟到第一帧渲染完成后再检查，避免阻塞 UI 初始化
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 1. 先检查是否有待安装包（上次下载完成但用户选择了「稍后」）
      if (mounted) {
        await UpdateNotificationService().checkAndInstallPending(context);
      }
      // 2. 再检查是否有新版本
      if (mounted) {
        _checkForUpdates();
      }
    });
  }

  Future<void> _checkForUpdates() async {
    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;
    if (result.hasUpdate && result.updateInfo != null) {
      await UpdateNotificationService().notifyUpdateAvailable(
        result.updateInfo!,
        context,
      );
    }
  }
}
```

**流程**:
1. App 启动完成后自动检查更新
2. 先检查是否有之前下载但未安装的包
3. 再进行新版本检查（自动受 6 小时冷却限制）

---

## 7. SharedPreferences 存储 (lib/services/update_service.dart)

```dart
// 键定义
static const String _prefLastCheckTimeKey = 'update_last_check_time';
static const String _prefSkippedVersionKey = 'update_skipped_version';
static const String _prefCachedUpdateKey = 'update_cached_info';

// 保存检查时间
Future<void> _saveLastCheckTime(DateTime time) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(
    _prefLastCheckTimeKey,
    time.millisecondsSinceEpoch,
  );
}

// 读取检查时间
Future<DateTime?> _getLastCheckTime() async {
  final prefs = await SharedPreferences.getInstance();
  final ms = prefs.getInt(_prefLastCheckTimeKey);
  if (ms == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

// 缓存更新信息
Future<void> _saveCachedUpdateInfo(UpdateInfo info) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefCachedUpdateKey, jsonEncode(info.toJson()));
}
```

**存储内容**:
- 最后一次检查的时间戳
- 最后一次检查的结果（更新信息或无更新）
- 用户跳过的版本号

---

## 8. API 请求构建 (lib/services/update_service.dart - 第 135-145 行)

```dart
final uri = Uri.parse('$_baseUrl$_checkEndpoint').replace(
  queryParameters: {
    'platform': platform,
    'currentVersion': currentVersion.versionString,
    'buildNumber': currentVersion.buildNumber.toString(),
  },
);

_logger.info('Checking for updates: $uri', tag: 'UpdateService');

final response = await http.get(uri).timeout(_requestTimeout);
```

**请求例子**:
```
GET http://release.shepaw.com/api/v1/check-update
  ?platform=ios
  &currentVersion=1.0.0
  &buildNumber=5
```

**响应**:
- `200 OK`: 新版本可用，返回 JSON
- `204 No Content`: 无新版本
- `4xx/5xx`: 服务器错误

---

## 📊 时间线示例

### 场景 1: 6 小时内的重复检查

```
时间      操作                        行为
07:00    App 启动 → 检查更新          发起请求，无更新，存储 07:00
08:00    App 启动 → 检查更新          elapsed = 1h < 6h，返回缓存，无新请求
12:00    App 启动 → 检查更新          elapsed = 5h < 6h，返回缓存，无新请求
13:00    App 启动 → 检查更新          elapsed = 6h >= 6h，发起新请求
```

### 场景 2: 失败后 1 小时重试

```
时间      操作                        行为
07:00    App 启动 → 检查更新          网络失败，存储 07:00-6h+1h = 02:00
08:00    App 启动 → 检查更新          elapsed = 8h >= 6h，发起新请求（失败的 1h 冷却已过）
```

---

## 🔑 关键数据模型

### UpdateCheckResult (lib/models/update_model.dart - 第 213-239 行)

```dart
class UpdateCheckResult {
  /// 是否有更新可用
  final bool hasUpdate;

  /// 更新信息（如果有更新）
  final UpdateInfo? updateInfo;

  /// 错误消息（如果检查失败）
  final String? error;

  /// 检查时间戳
  final DateTime timestamp;

  UpdateCheckResult({
    required this.hasUpdate,
    this.updateInfo,
    this.error,
    required this.timestamp,
  });

  /// 检查是否失败
  bool get isFailed => error != null && !hasUpdate;

  /// 是否是必须更新
  bool get isMandatory => hasUpdate && updateInfo?.isMandatory == true;
}
```

---

## 📌 修改更新检查频率的方法

### 方法 1: 修改成功检查间隔 (从 6 小时改为 24 小时)

**文件**: `lib/services/update_service.dart`

**修改前**:
```dart
static const Duration _minCheckInterval = Duration(hours: 6);
```

**修改后**:
```dart
static const Duration _minCheckInterval = Duration(hours: 24);
```

---

### 方法 2: 修改失败重试间隔 (从 1 小时改为 30 分钟)

**文件**: `lib/services/update_service.dart`

**修改前**:
```dart
static const Duration _errorRetryInterval = Duration(hours: 1);
```

**修改后**:
```dart
static const Duration _errorRetryInterval = Duration(minutes: 30);
```

---

### 方法 3: 修改请求超时时间 (从 10 秒改为 30 秒)

**文件**: `lib/services/update_service.dart`

**修改前**:
```dart
static const Duration _requestTimeout = Duration(seconds: 10);
```

**修改后**:
```dart
static const Duration _requestTimeout = Duration(seconds: 30);
```

---

## ✅ 完整的更新检查流程图

```
┌─────────────────────┐
│   App 启动完成      │
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────┐
│  检查待安装的更新包？    │
│  (上次下载但用户选稍后) │
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────────────┐
│  调用 checkForUpdate()            │
│  (force = false, 自动检查)        │
└──────────┬───────────────────────┘
           │
           ▼
      ┌─────────────────┐
      │ force = true?   │
      └─┬───────────┬───┘
        │           │
    不绕过冷却   绕过冷却
        │           │
        ▼           │
┌──────────────────────────┐
│ 读取上次检查时间         │ ◄──────┐
│ elapsed < 6h?            │       │
└─┬────────────┬───────────┘       │
  │            │                   │
 是             否                 │
  │            │                   │
  ▼            ▼                   │
返回缓存   发送 HTTP 请求          │
  │            │                   │
  │            ▼                   │
  │      ┌─────────────────┐       │
  │      │ 响应状态？      │       │
  │      └─┬───┬───┬───┬───┘       │
  │        │   │   │   │           │
  │       200 204 超时 其他         │
  │        │   │   │   │           │
  │        ▼   ▼   ▼   ▼           │
  │      更新 无更 失败 失败        │
  │      可用 新   错误  错误       │
  │        │   │   │   │           │
  │        ▼   ▼   ▼   ▼           │
  │      存储检查时间               │
  │      (6h冷却)  (1h冷却)        │
  │        │   │   │   │           │
  └────────┴───┴───┴───┘           │
           │                       │
           ▼                       │
    返回 UpdateCheckResult         │
           │                       │
           ▼                       │
      有新版本？                   │
        │   │                      │
       是   否                      │
        │   │                      │
        ▼   ▼                      │
    发送   返回                    │
    通知                           │
```

