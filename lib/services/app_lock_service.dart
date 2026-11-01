import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/platform_utils.dart';
import 'biometric_service.dart';

/// 打开 App 时要不要先验证身份。
///
/// 手机默认开，桌面默认关（决定 D4）：手机丢了比电脑丢了常见得多。
/// 只在**本机有登录态**时才真的锁 —— 还没登录过的门页本来就没什么可保护的。
/// 那个判断在调用方（`_MyAppState`），因为它要读会话。
class AppLockService extends ChangeNotifier {
  AppLockService({
    Future<bool> Function()? authenticate,
    Future<bool> Function()? deviceSupported,
    Duration? away,
  })  : _authenticate = authenticate ??
            (() => BiometricService().authenticate(reason: 'verify')),
        _deviceSupported = deviceSupported ??
            (() => BiometricService().isDeviceSupported()),
        _away = away ?? const Duration(minutes: 5);

  static const key = 'app_lock_enabled';

  /// 后台超过这么久回来就重新锁。
  final Duration _away;
  final Future<bool> Function() _authenticate;
  final Future<bool> Function() _deviceSupported;

  bool? _enabled;
  bool _locked = false;
  bool _supported = true;
  DateTime? _pausedAt;

  /// 开关还没读过时为 null。
  bool? get enabled => _enabled;

  bool get locked => _locked;

  /// 设备根本没设过锁屏方式：开不了，也不提示。
  bool get supported => _supported;

  Duration get away => _away;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getBool(key);
    // 没设过就按平台给默认值：手机开，桌面关。
    final next = raw ?? !isDesktopPlatform;
    _supported = await _deviceSupported();
    _enabled = _supported ? next : false;
    _locked = _enabled == true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (!_supported) return;
    if (value) {
      // 开之前先过一次认证：免得拿不到验证的人把开关打开了。
      if (!await _authenticate()) return;
    }
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    if (!value) _locked = false;
    notifyListeners();
  }

  /// 认证通过才放行。失败就保持锁着，不提供任何绕过方式。
  Future<bool> unlock() async {
    if (!await _authenticate()) return false;
    _locked = false;
    _pausedAt = null;
    notifyListeners();
    return true;
  }

  /// 进后台：记下时间。
  void onPaused() {
    _pausedAt = DateTime.now();
  }

  /// 回前台：超过 [_away] 就重新锁。
  void onResumed() {
    final paused = _pausedAt;
    _pausedAt = null;
    if (_enabled != true || paused == null || _locked) return;
    if (DateTime.now().difference(paused) < _away) return;
    _locked = true;
    notifyListeners();
  }

  /// 测试用：直接推进「离开多久」这段，不用真的等。
  @visibleForTesting
  void debugResumeAfter(Duration gone) {
    _pausedAt = DateTime.now().subtract(gone);
    onResumed();
  }
}
