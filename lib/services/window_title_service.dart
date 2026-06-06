import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Syncs the native OS window title with the in-app locale on desktop.
class WindowTitleService {
  WindowTitleService._();

  static const _channel = MethodChannel('shepaw/window');

  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  static Future<void> setTitle(String title) async {
    if (!isSupported || title.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('setTitle', title);
    } catch (_) {
      // Native handler may be unavailable during tests or on unsupported builds.
    }
  }
}
