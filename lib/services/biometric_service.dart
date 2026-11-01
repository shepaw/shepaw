import 'dart:io' show Platform;
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BiometricService {
  static const _key = 'biometric_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

  /// Whether the current platform supports biometric via local_auth.
  bool get _platformSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Check if the device supports biometric authentication.
  ///
  /// Returns true only when the device hardware supports biometrics AND
  /// at least one biometric credential is enrolled. On some Android devices
  /// (e.g. Samsung), [isDeviceSupported] alone returns true even when no
  /// fingerprint is enrolled, which causes the Switch to appear enabled but
  /// authentication always fails.
  Future<bool> isDeviceSupported() async {
    if (!_platformSupported) return false;
    try {
      final deviceSupported = await _auth.isDeviceSupported();
      if (!deviceSupported) return false;
      // Also verify that at least one biometric is actually enrolled.
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return false;
      final available = await _auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Get the list of available biometric types on the device.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    if (!_platformSupported) return [];
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  /// Trigger biometric authentication with the given [reason] prompt.
  /// Returns true if authentication succeeded.
  ///
  /// On Android, [biometricOnly] is set to false so that the system can
  /// fall back to device credentials (PIN/pattern/password) if the biometric
  /// prompt is dismissed or fails — this avoids issues on Samsung devices
  /// where the biometric-only dialog sometimes cannot be presented.
  Future<bool> authenticate({required String reason}) async {
    if (!_platformSupported) return false;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: !Platform.isAndroid,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// 这台设备上「验证身份」叫什么：Touch ID / Face ID / 指纹 / Windows Hello。
  ///
  /// 界面上不能一律写「生物识别」—— Mac 上是 Touch ID，Windows 上是 Hello。
  /// 没有可用的生物识别时用「设备密码」：local_auth 仍会落到系统凭据。
  Future<String> methodLabel() async {
    if (!_platformSupported) return '设备密码';
    try {
      final available = await _auth.getAvailableBiometrics();
      if (available.contains(BiometricType.face)) return 'Face ID';
      if (available.contains(BiometricType.fingerprint)) {
        return Platform.isMacOS ? 'Touch ID' : '指纹';
      }
      if (available.contains(BiometricType.iris)) return '虹膜';
      if (Platform.isWindows) return 'Windows Hello';
      return '设备密码';
    } catch (_) {
      return '设备密码';
    }
  }

  /// Read the biometric enabled preference.
  Future<bool> isBiometricEnabled() async {
    if (!_platformSupported) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// Save the biometric enabled preference.
  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}
