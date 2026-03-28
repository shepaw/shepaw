import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/update_model.dart';
import 'logger_service.dart';

/// 自动更新服务
///
/// 负责从 release.shepaw.com 检查并管理应用更新。
///
/// ## 请求频率控制
///
/// - 成功/无更新：6 小时冷却（[_minCheckInterval]）
/// - 网络失败/服务不可用：1 小时冷却（[_errorRetryInterval]），避免服务持续不可用时每次启动都尝试
/// - [force] = true：绕过冷却，用于用户手动触发
///
/// API 约定（后端待实现）：
/// GET https://release.shepaw.com/api/v1/check-update
///
/// Query Parameters:
///   - platform: "ios" | "android" | "macos" | "windows" | "linux"
///   - currentVersion: 当前版本号，格式 "1.2.3"
///   - buildNumber: 当前构建号，格式 "4"
///
/// Response (200 OK):
/// ```json
/// {
///   "version": "1.2.3",
///   "buildNumber": "5",
///   "description": "更新内容...",
///   "isMandatory": false,
///   "releaseDate": "2024-03-24T10:30:00Z",
///   "downloadUrl": "https://release.shepaw.com/download/...",
///   "fileSize": 12345678,
///   "checksum": "sha256:abcdef...",
///   "minIosVersion": "14.0",
///   "minAndroidSdk": 21,
///   "minMacOSVersion": "11.0",
///   "minWindowsVersion": "10.0"
/// }
/// ```
///
/// Response (204 No Content): 没有可用更新
///
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  static const String _baseUrl = String.fromEnvironment(
    'UPDATE_BASE_URL',
    defaultValue: 'http://release.shepaw.com',
  );
  static const String _checkEndpoint = String.fromEnvironment(
    'UPDATE_CHECK_ENDPOINT',
    defaultValue: '/api/v1/check-update',
  );

  static const String _prefLastCheckTimeKey = 'update_last_check_time';
  static const String _prefSkippedVersionKey = 'update_skipped_version';
  static const String _prefCachedUpdateKey = 'update_cached_info';

  /// 正常冷却间隔：成功或无更新后 6 小时内不重复请求
  static const Duration _minCheckInterval = Duration(hours: 6);

  /// 失败冷却间隔：网络错误或服务不可用后 1 小时内不重试，避免每次启动都尝试
  static const Duration _errorRetryInterval = Duration(hours: 1);

  /// HTTP 请求超时时间
  static const Duration _requestTimeout = Duration(seconds: 10);

  final _logger = LoggerService();

  /// 当前应用信息（懒加载缓存）
  PackageInfo? _packageInfo;

  // ==================== 公开 API ====================

  /// 获取当前安装的版本信息
  Future<VersionInfo> getCurrentVersion() async {
    final info = await _getPackageInfo();
    return VersionInfo.parse('${info.version}+${info.buildNumber}');
  }

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

    try {
      final currentVersion = await getCurrentVersion();
      final platform = _getPlatformString();

      if (platform == null) {
        _logger.info(
          'Auto-update not supported on this platform (web)',
          tag: 'UpdateService',
        );
        return UpdateCheckResult(hasUpdate: false, timestamp: now);
      }

      final uri = Uri.parse('$_baseUrl$_checkEndpoint').replace(
        queryParameters: {
          'platform': platform,
          'currentVersion': currentVersion.versionString,
          'buildNumber': currentVersion.buildNumber.toString(),
        },
      );

      _logger.info('Checking for updates: $uri', tag: 'UpdateService');

      final response = await http.get(uri).timeout(_requestTimeout);

      // 请求成功（无论有无更新），记录检查时间（使用正常冷却）
      await _saveLastCheckTime(now);

      if (response.statusCode == 204) {
        // 无可用更新
        await _clearCachedUpdateInfo();
        _logger.info('No update available', tag: 'UpdateService');
        return UpdateCheckResult(hasUpdate: false, timestamp: now);
      }

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final updateInfo = UpdateInfo.fromJson(json);
        final latestVersion = VersionInfo.parse(
          '${updateInfo.version}+${json['buildNumber'] ?? 0}',
        );

        if (currentVersion.isLowerThan(latestVersion)) {
          // 确认服务端版本确实比本地版本新
          final skippedVersion = await _getSkippedVersion();
          if (!updateInfo.isMandatory &&
              skippedVersion == latestVersion.versionString) {
            // 用户已跳过此版本
            _logger.info(
              'Update ${latestVersion.versionString} was skipped by user',
              tag: 'UpdateService',
            );
            await _clearCachedUpdateInfo();
            return UpdateCheckResult(hasUpdate: false, timestamp: now);
          }

          await _saveCachedUpdateInfo(updateInfo);
          _logger.info(
            'Update available: ${latestVersion.versionString}',
            tag: 'UpdateService',
          );
          return UpdateCheckResult(
            hasUpdate: true,
            updateInfo: updateInfo,
            timestamp: now,
          );
        } else {
          // 服务端版本不高于当前版本（可能是配置错误），视为无更新
          await _clearCachedUpdateInfo();
          return UpdateCheckResult(hasUpdate: false, timestamp: now);
        }
      }

      // 其他 HTTP 状态码（4xx/5xx），使用失败冷却
      _logger.warning(
        'Unexpected HTTP status: ${response.statusCode}',
        tag: 'UpdateService',
      );
      await _saveLastCheckTime(
        now.subtract(_minCheckInterval).add(_errorRetryInterval),
      );
      return UpdateCheckResult(
        hasUpdate: false,
        error: 'HTTP ${response.statusCode}',
        timestamp: now,
      );
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
    } catch (e, stack) {
      // 其他未预期的错误（JSON 解析错误等）
      _logger.error(
        'Failed to check for update',
        tag: 'UpdateService',
        error: e,
        stackTrace: stack,
      );
      await _saveLastCheckTime(
        now.subtract(_minCheckInterval).add(_errorRetryInterval),
      );
      return UpdateCheckResult(
        hasUpdate: false,
        error: e.toString(),
        timestamp: now,
      );
    }
  }

  /// 跳过指定版本（用户选择"稍后提醒"后的下一次可跳过）
  Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSkippedVersionKey, version);
    _logger.info('User skipped version $version', tag: 'UpdateService');
  }

  /// 清除已跳过的版本（用户手动检查更新时应调用）
  Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefSkippedVersionKey);
  }

  // ==================== 私有辅助方法 ====================

  /// 获取当前平台字符串
  String? _getPlatformString() {
    if (kIsWeb) return null;
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return null;
  }

  /// 获取包信息（带缓存）
  Future<PackageInfo> _getPackageInfo() async {
    _packageInfo ??= await PackageInfo.fromPlatform();
    return _packageInfo!;
  }

  Future<DateTime?> _getLastCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefLastCheckTimeKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> _saveLastCheckTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _prefLastCheckTimeKey,
      time.millisecondsSinceEpoch,
    );
  }

  Future<String?> _getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefSkippedVersionKey);
  }

  Future<UpdateInfo?> _getCachedUpdateInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefCachedUpdateKey);
    if (json == null) return null;
    try {
      return UpdateInfo.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedUpdateInfo(UpdateInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCachedUpdateKey, jsonEncode(info.toJson()));
  }

  Future<void> _clearCachedUpdateInfo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefCachedUpdateKey);
  }
}
