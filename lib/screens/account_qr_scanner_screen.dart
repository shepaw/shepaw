import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';

/// 扫描账号 Trust / 身份相关 QR，返回原始字符串。
class AccountQrScannerScreen extends StatefulWidget {
  const AccountQrScannerScreen({super.key});

  static Future<String?> show(BuildContext context) {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute<String?>(
        builder: (_) => const AccountQrScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<AccountQrScannerScreen> createState() => _AccountQrScannerScreenState();
}

class _AccountQrScannerScreenState extends State<AccountQrScannerScreen> {
  MobileScannerController? _controller;
  bool _dispatched = false;
  bool _busy = true;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    final ctrl = _controller;
    if (ctrl != null) unawaited(ctrl.dispose().catchError((_) {}));
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_isDesktop) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _busy = false);
      return;
    }
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
    setState(() => _busy = false);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_dispatched) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _dispatched = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identity_scanTrustQr)),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _isDesktop || _controller == null
              ? Center(child: Text(l10n.identity_scanUnsupported))
              : MobileScanner(controller: _controller!, onDetect: _onDetect),
    );
  }
}
