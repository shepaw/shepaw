# 🚀 快速参考 - App 更新下载流程

## 问题症状
✗ 点击"下载现在"按钮 → 没有反应 → 后台没有收到下载请求

---

## 📍 关键代码位置速查表

### 1. **设置页面** 
📄 `lib/screens/settings_screen.dart:513`
```dart
const CheckForUpdatesListTile(),  // 检查更新入口
```

---

### 2. **检查更新并显示对话框**
📄 `lib/widgets/update_dialog.dart:225-261`

```dart
class _CheckForUpdatesListTileState {
  Future<void> _check() async {
    // ↓ 调用检查更新服务
    final result = await UpdateService().checkForUpdate(force: true);
    
    if (result.hasUpdate && result.updateInfo != null) {
      // ↓ 显示更新对话框
      await UpdateDialog.show(context, ...);
    }
  }
}
```

---

### 3. **点击"下载现在"按钮** ⭐ 关键！
📄 `lib/widgets/update_dialog.dart:146-192`

```dart
FilledButton.icon(
  onPressed: () => _handleDownload(context),  // ← 点击时触发
  icon: const Icon(Icons.download, size: 18),
  label: Text(l10n.update_downloadNow),
),
```

**完整处理逻辑:**
```dart
Future<void> _handleDownload(BuildContext context) async {
  // 1️⃣ 检测是否是桌面平台
  final isDesktop = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  if (isDesktop && updateInfo.downloadUrl.isNotEmpty) {
    // 2️⃣ 显示下载进度对话框
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDownloadDialog(
        downloadUrl: updateInfo.downloadUrl,  // ← 关键：传入 URL
        fileName: fileName,
        totalSize: updateInfo.fileSize,
      ),
    );
  } else {
    // 移动端：打开外部链接
    await launchUrl(Uri.parse(updateInfo.downloadUrl), ...);
  }
}
```

---

### 4. **下载进度对话框初始化**
📄 `lib/widgets/update_download_dialog.dart:33-38`

```dart
@override
void initState() {
  super.initState();
  _downloadService = FileDownloadService();
  _startTime = DateTime.now();
  _startDownload();  // ← 立即开始下载！
}
```

---

### 5. **执行下载** ⭐ 真正发送网络请求的地方！
📄 `lib/widgets/update_download_dialog.dart:40-62`

```dart
Future<void> _startDownload() async {
  try {
    // ↓ 调用下载服务
    await _downloadService.downloadAndSave(
      widget.downloadUrl,        // ← URL 来自 UpdateDialog
      fileName: widget.fileName,
      expectedSize: widget.totalSize,
      onProgress: _handleProgress,  // ← 进度回调
    );
    
    if (!mounted) return;
    setState(() => _state = UpdateDownloadState.completed);
    
    // 下载完成 1 秒后自动关闭
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) Navigator.of(context).pop(true);
  } catch (e) {
    // 异常处理
    setState(() {
      _state = UpdateDownloadState.failed;
      _error = e.toString();
    });
  }
}
```

---

### 6. **真正的 HTTP 下载**
📄 `lib/services/file_download_service.dart:48-138`

```dart
Future<FileDownloadResult> downloadAndSave(
  String url, {
  void Function(int received, int? total)? onProgress,
  // ...
}) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final streamedResponse = await client.send(request);  // ← HTTP GET 请求
    
    if (streamedResponse.statusCode != 200) {
      throw Exception('HTTP ${streamedResponse.statusCode}');
    }
    
    // 流式接收、写入文件、回调进度
    await for (final chunk in streamedResponse.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);  // ← 进度更新
    }
    
    // 保存到永久存储
    final relativePath = await _storageService.saveFile(tempFile, ...);
    return FileDownloadResult(...);
  } finally {
    client.close();
  }
}
```

---

## 🔗 完整调用链

```
用户在设置页面点击"检查更新"
    ↓
[CheckForUpdatesListTile._check()]
    ↓
[UpdateService.checkForUpdate()]
    ├─ HTTP GET: release.shepaw.com/api/v1/check-update
    ↓
[UpdateCheckResult: hasUpdate=true, updateInfo={...downloadUrl...}]
    ↓
[UpdateDialog.show()]
    ↓ 用户看到新版本信息，点击"下载现在"
[UpdateDialog._handleDownload()]
    ↓
[UpdateDownloadDialog] (显示下载进度)
    ↓
[UpdateDownloadDialog.initState()] → [_startDownload()]
    ↓
[FileDownloadService.downloadAndSave(downloadUrl)]
    ↓
[HTTP GET: <downloadUrl>]  ⭐ 这里是关键！
    ↓
[流式下载、保存文件、显示进度]
```

---

## 🔴 潜在故障点排查

| # | 故障点 | 症状 | 原因 | 修复 |
|---|-------|------|------|------|
| 1 | API 响应 | 对话框显示但 `downloadUrl` 为空 | 后端返回的 `downloadUrl` 字段缺失 | 检查 API 响应 JSON |
| 2 | 平台检测 | 没有弹出下载对话框 | `isDesktop` 判断错误 | 添加日志: `print('$defaultTargetPlatform')` |
| 3 | Context | 按钮点击后立即消失 | `context.mounted` 为 false | 检查导航器状态 |
| 4 | URL 有效性 | 下载对话框显示但无进度 | 下载 URL 不可达或格式错误 | 网络抓包验证 URL |
| 5 | 网络请求 | 看不到 HTTP 请求 | 防火墙/代理拦截 | 检查网络配置 |
| 6 | 异常处理 | 没有错误提示 | 异常被捕获但未记录 | 添加日志输出 |

---

## 🧪 快速测试方法

### 方式 1: 添加日志调试

在 `lib/widgets/update_dialog.dart` 中 `_handleDownload()` 方法开始处添加：

```dart
Future<void> _handleDownload(BuildContext context) async {
  print('=== DEBUG: _handleDownload called ===');
  print('downloadUrl: ${updateInfo.downloadUrl}');
  print('isDesktop: ${!kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)}');
  print('context.mounted: ${context.mounted}');
  
  // ... 原有逻辑 ...
}
```

在 `lib/widgets/update_download_dialog.dart` 中 `_startDownload()` 方法开始处添加：

```dart
Future<void> _startDownload() async {
  print('=== DEBUG: _startDownload called ===');
  print('downloadUrl: ${widget.downloadUrl}');
  print('fileName: ${widget.fileName}');
  print('totalSize: ${widget.totalSize}');
  
  try {
    await _downloadService.downloadAndSave(
      widget.downloadUrl,
      fileName: widget.fileName,
      expectedSize: widget.totalSize,
      onProgress: _handleProgress,
    );
    // ...
  } catch (e) {
    print('=== DEBUG: Download failed ===');
    print('Error: $e');
    // ...
  }
}
```

### 方式 2: 网络抓包
- 使用 Charles 或 Fiddler 进行中间人抓包
- 查看是否有发送到下载 URL 的 HTTP 请求
- 检查响应状态码和响应体

### 方式 3: 直接测试下载服务

```dart
// 在某个测试页面或临时代码中
final service = FileDownloadService();
try {
  final result = await service.downloadAndSave(
    'https://example.com/test-file.zip',
    fileName: 'test.zip',
    onProgress: (received, total) {
      print('Download: $received / $total');
    },
  );
  print('Success: ${result.relativePath}');
} catch (e) {
  print('Error: $e');
}
```

---

## 📦 数据流示例

### 更新信息 JSON
```json
{
  "version": "1.2.3",
  "buildNumber": "5",
  "description": "新版本功能...",
  "isMandatory": false,
  "releaseDate": "2024-03-24T10:30:00Z",
  "downloadUrl": "https://release.shepaw.com/download/shepaw-1.2.3.dmg",  // ← 关键
  "fileSize": 123456789,
  "checksum": "sha256:abc...",
  "minMacOSVersion": "11.0"
}
```

### 下载过程中的状态
```dart
UpdateDownloadState.downloading  // 初始状态
  ↓
_progress: DownloadProgress(
  downloadedBytes: 10485760,
  totalBytes: 123456789,
)
  ↓
// UI 显示: 8% - 12.3 MB / 123.5 MB
  ↓
// 进度更新循环...
  ↓
UpdateDownloadState.completed  // 完成
```

---

## ⚠️ 常见错误及修复

### 错误 1: `downloadUrl` 为空

**症状**: 对话框显示新版本，但点击下载后无反应

**原因**: `UpdateInfo.downloadUrl` 为空字符串

**修复** - 在 `_handleDownload()` 中添加检查:

```dart
if (updateInfo.downloadUrl.isEmpty) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Download URL is empty!'))
  );
  return;
}
```

---

### 错误 2: 平台检测失败

**症状**: 桌面版点击"下载"后跳转浏览器，而不是显示进度对话框

**原因**: `isDesktop` 判断逻辑错误或 `defaultTargetPlatform` 值异常

**修复** - 添加日志查看:

```dart
print('kIsWeb: $kIsWeb');
print('Platform: $defaultTargetPlatform');
print('Expected: TargetPlatform.macOS / windows / linux');
```

---

### 错误 3: 异常被吞掉

**症状**: 下载对话框弹出，显示"完成"，但实际没下载

**原因**: `_startDownload()` 中的 `catch` 块没有日志

**修复** - 增强异常处理:

```dart
} catch (e, stackTrace) {
  print('Error: $e');
  print('StackTrace: $stackTrace');
  // 可选: 发送到日志服务
  _logger.error('Download failed', error: e, stackTrace: stackTrace);
  
  if (!mounted) return;
  setState(() {
    _state = UpdateDownloadState.failed;
    _error = e.toString();
  });
}
```

---

## 📌 总结

**下载流程简图:**

```
CheckForUpdatesListTile
    ↓ 用户点击"检查更新"
UpdateService.checkForUpdate()
    ↓ API 返回 {downloadUrl: "https://..."}
UpdateDialog.show()
    ↓ 用户看到版本信息
UpdateDialog._handleDownload()  ⭐ 关键触发点
    ↓ 检测平台
UpdateDownloadDialog()
    ↓ initState() → _startDownload()
FileDownloadService.downloadAndSave()
    ↓ HTTP GET request
File downloaded & saved ✓
```

**最可能的问题原因:**

1. ✗ `downloadUrl` 为空或不合法
2. ✗ 平台检测错误（认为是移动端而非桌面端）
3. ✗ 网络请求被拦截或超时
4. ✗ 文件保存权限问题
5. ✗ 异常被吞掉，导致静默失败

