import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Service to manage native OS sub-windows on desktop platforms.
///
/// Uses [desktop_multi_window] to create true native windows that can be
/// freely moved outside the main application window. On unsupported platforms,
/// [isSupported] returns false and callers should fall back to in-app panels.
class NativeWindowService {
  NativeWindowService._();
  static final NativeWindowService instance = NativeWindowService._();

  /// Whether native multi-window is supported on the current platform.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  /// Tracks open sub-windows by logical key (e.g. 'inference_log', 'system_log').
  final Map<String, WindowController> _windows = {};

  /// Opens a native sub-window for the given [key], or brings an existing one
  /// to front if already open.
  ///
  /// [title] is informational only (used by the sub-window app bar).
  /// [locale] is the language code to pass to the sub-window (e.g. 'zh', 'en').
  /// [width] and [height] set the initial window size.
  Future<void> openPanel({
    required String key,
    required String title,
    String? locale,
    double width = 800,
    double height = 600,
  }) async {
    // Check if there's already a window for this key.
    if (_windows.containsKey(key)) {
      try {
        // Attempt to bring to front by showing it.
        // If the user closed the window via OS close button, this may throw.
        await _windows[key]!.show();
        return;
      } catch (_) {
        // Stale controller — the window was closed by the user. Remove it.
        _windows.remove(key);
      }
    }

    // Check if there's a matching window already running (e.g. after a
    // hot-restart where our in-memory map was lost).
    try {
      final allWindows = await WindowController.getAll();
      for (final wc in allWindows) {
        try {
          final args = jsonDecode(wc.arguments) as Map<String, dynamic>;
          if (args['key'] == key) {
            _windows[key] = wc;
            await wc.show();
            return;
          }
        } catch (_) {
          // Not our window or bad JSON — skip.
        }
      }
    } catch (_) {
      // getAll() may fail on some platforms — proceed to create.
    }

    // Create a new native window.
    final arguments = jsonEncode({
      'key': key,
      'title': title,
      'locale': locale,
    });

    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: arguments,
        hiddenAtLaunch: false,
      ),
    );

    _windows[key] = controller;
  }

  /// Hides the sub-window with the given [key] (if it exists).
  Future<void> closePanel(String key) async {
    final controller = _windows.remove(key);
    if (controller == null) return;
    try {
      await controller.hide();
    } catch (_) {
      // Window already closed by user — ignore.
    }
  }

  /// Hides all tracked sub-windows. Called when the main app is disposed.
  Future<void> closeAll() async {
    final entries = Map<String, WindowController>.from(_windows);
    _windows.clear();
    for (final controller in entries.values) {
      try {
        await controller.hide();
      } catch (_) {
        // Already closed — ignore.
      }
    }
  }
}
