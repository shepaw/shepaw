import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/logger_service.dart';
import '../services/pair_deeplink.dart';

/// Full-screen camera scanner for v2.1 pairing QR codes.
///
/// Flow:
///   1. Ask for camera permission if we don't have it yet.
///   2. Open a `MobileScanner` view with a centered crosshair overlay.
///   3. On detect, try to parse the payload as a `shepaw://pair?...`
///      deep-link. On success, pop back to the caller with the parsed
///      `PairDeeplink`. On failure, show a SnackBar and keep scanning.
///   4. Torch toggle in the AppBar; tapping cancel / back pops with null.
///
/// The caller (AddRemoteAgentScreen) receives either `PairDeeplink` or null
/// via `Navigator.push<PairDeeplink?>`. null covers all three "no result"
/// paths: user cancelled, permission denied, unsupported platform.
///
/// On desktop platforms (macOS/Linux/Windows) we short-circuit with an
/// "unsupported" message instead of loading `mobile_scanner` — the package
/// only implements iOS + Android, and importing the native bindings on
/// desktop raises a runtime MissingPluginException. Users on desktop
/// retain the typed-short-code fallback we already have.
class PairingQRScannerScreen extends StatefulWidget {
  const PairingQRScannerScreen({super.key});

  static const String routeName = '/add-agent/scan-qr';

  /// Helper that hides the platform/permission dance from callers.
  /// Returns the parsed PairDeeplink on success, or null if the user
  /// backed out / lacked permission / is on a desktop platform.
  static Future<PairDeeplink?> show(BuildContext context) {
    return Navigator.of(context).push<PairDeeplink?>(
      MaterialPageRoute<PairDeeplink?>(
        builder: (_) => const PairingQRScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PairingQRScannerScreen> createState() => _PairingQRScannerScreenState();
}

class _PairingQRScannerScreenState extends State<PairingQRScannerScreen>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _hasPermission = false;
  bool _permissionDenied = false;
  bool _busy = true;
  String? _lastError;

  /// Guards against the scanner firing multiple times for the same QR
  /// while we navigate back. Without this, a fast detector can push the
  /// result twice and we'd try to pop past our own page.
  bool _dispatched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // mobile_scanner 5.x made `dispose` async (needs to tear down a
    // platform-channel subscription). Flutter's State.dispose contract is
    // synchronous, so we kick it off and move on — any exception here
    // would happen during tear-down and has no UI to surface to.
    final ctrl = _controller;
    if (ctrl != null) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause the camera when the app goes to background — prevents an
    // ANR on some Android devices when the OS reclaims the camera, and
    // stops wasted battery when the user switches apps mid-scan.
    //
    // start()/stop() are async in 5.x and can throw MobileScannerException
    // if called in the wrong state (e.g. stop on an uninitialized camera,
    // or start after dispose). We swallow those — a lifecycle callback is
    // the wrong place to surface errors to the user, and the permission
    // / init errors are already handled by _bootstrap and errorBuilder.
    final ctrl = _controller;
    if (ctrl == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(ctrl.start().catchError((_) {}));
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(ctrl.stop().catchError((_) {}));
        break;
    }
  }

  Future<void> _bootstrap() async {
    if (_isDesktop) {
      // Desktop doesn't have mobile_scanner. Surface a clear message and
      // let the user back out to the typed fallback.
      setState(() {
        _busy = false;
        _lastError =
            '当前平台不支持扫码。请返回手动粘贴 URL + 填写配对码，或改用手机扫码。';
      });
      return;
    }

    final granted = await _ensureCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _busy = false;
        _permissionDenied = true;
      });
      return;
    }

    // Permission granted — construct the controller.
    // We keep defaults (auto-select back camera, auto-focus). The torch
    // toggle drives `toggleTorch()` on user action.
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      // Return the raw value string; the SDK also ships a Barcode object
      // with type metadata but we only need the text payload.
      returnImage: false,
    );
    setState(() {
      _hasPermission = true;
      _busy = false;
    });
  }

  Future<bool> _ensureCameraPermission() async {
    try {
      final status = await Permission.camera.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        // User denied "don't ask again" earlier — request() won't re-prompt.
        // Surface a direct-to-settings option.
        return false;
      }
      final result = await Permission.camera.request();
      return result.isGranted;
    } catch (err, stack) {
      // Permission backend failure (unlikely on iOS/Android; possible on
      // odd embeds). Log and fall through — `_bootstrap` will treat this
      // as denied so the user sees a message.
      LoggerService().error(
        'Camera permission check failed',
        tag: 'QRScanner',
        error: err,
        stackTrace: stack,
      );
      return false;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_dispatched) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final parsed = parsePairDeeplink(raw);
        _dispatched = true;
        // stop() is async in 5.x; we don't need to await before popping —
        // dispose() (fired from the State lifecycle when the screen pops)
        // will guarantee teardown. Fire-and-forget is deliberate.
        final ctrl = _controller;
        if (ctrl != null) {
          unawaited(ctrl.stop().catchError((_) {}));
        }
        Navigator.of(context).pop(parsed);
        return;
      } on PairDeeplinkError catch (e) {
        // Not a pairing QR (or malformed). Keep scanning; show a toast.
        _showTransientError(e.message);
      } catch (err, stack) {
        LoggerService().error(
          'Unexpected error parsing QR payload',
          tag: 'QRScanner',
          error: err,
          stackTrace: stack,
        );
        _showTransientError('扫描失败：${err.runtimeType}');
      }
    }
  }

  /// Throttle toast messages — rapid re-detection of the same bad QR
  /// would otherwise spam SnackBars and block the retry.
  DateTime? _lastToastAt;
  void _showTransientError(String message) {
    final now = DateTime.now();
    if (_lastToastAt != null &&
        now.difference(_lastToastAt!).inMilliseconds < 1500) {
      return;
    }
    _lastToastAt = now;
    setState(() => _lastError = message);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('扫描配对二维码'),
        actions: [
          if (_hasPermission)
            IconButton(
              icon: ValueListenableBuilder<MobileScannerState>(
                // mobile_scanner 5.x: MobileScannerController is itself a
                // ValueListenable<MobileScannerState>. The torch state is
                // a field on that state struct. When downgrading to 3.x,
                // this listens on `_controller.torchState` (a standalone
                // ValueNotifier<TorchState>) instead.
                valueListenable: _controller!,
                builder: (_, state, __) {
                  final torch = state.torchState;
                  IconData icon;
                  switch (torch) {
                    case TorchState.on:
                      icon = Icons.flash_on;
                      break;
                    case TorchState.off:
                    case TorchState.auto:
                      icon = Icons.flash_off;
                      break;
                    case TorchState.unavailable:
                      icon = Icons.flash_off;
                      break;
                  }
                  return Icon(icon);
                },
              ),
              tooltip: '手电筒',
              onPressed: () => _controller?.toggleTorch(),
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_busy) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_permissionDenied) {
      return _buildPermissionDenied(context);
    }
    if (_isDesktop || _controller == null) {
      return _buildUnsupported(context);
    }
    return Stack(
      children: [
        MobileScanner(
          controller: _controller!,
          onDetect: _onDetect,
          errorBuilder: (context, error, _) => _buildScannerError(context, error),
        ),
        // Darkened overlay with a centered cutout. Simple implementation:
        // two horizontal bars + a framed square. Not a fancy scanline
        // animation — users understand a rectangle.
        IgnorePointer(
          child: _ScannerOverlay(),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '对准 agent 主机上 `<gateway> enroll` / `shepaw-hub pair` 打印的二维码',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              if (_lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _lastError!,
                  style: TextStyle(
                    color: Colors.orange.shade200,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionDenied(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          const Text(
            '无法访问相机',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 8),
          const Text(
            '扫码配对需要相机权限。请到系统设置中允许 Shepaw 访问相机，或返回手动输入配对码。',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.settings),
            label: const Text('打开设置'),
            onPressed: () async => openAppSettings(),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupported(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.desktop_access_disabled,
              color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          Text(
            _lastError ?? '当前平台暂不支持扫码',
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerError(BuildContext context, MobileScannerException error) {
    // Platform-level failure (e.g. hardware init). Not a parse error.
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          Text(
            '相机初始化失败：${error.errorCode.name}',
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  /// mobile_scanner doesn't ship for desktop. We could probably add web
  /// later, but for now bail early with a clean message.
  bool get _isDesktop {
    if (kIsWeb) return false; // treat web as "mobile-ish" if enabled later
    return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
  }
}

/// Darkened overlay with a centered square cutout. Keeps the layout
/// purely visual — the scanner itself scans the whole frame; the cutout
/// is just guidance.
class _ScannerOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth * 0.7;
        return Center(
          child: Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      },
    );
  }
}
