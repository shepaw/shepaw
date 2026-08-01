import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/pairing_payload.dart';

/// 换机导入：扫描/粘贴旧设备配对 QR，仅解析 [PeerPairingInfo]（取 fingerprint），
/// 不在此页发起配对——由调用方决定是否先配对再发 import.request。
class StorageImportScannerScreen extends StatefulWidget {
  const StorageImportScannerScreen({super.key});

  /// 返回解析到的配对信息；取消则为 null。
  static Future<PeerPairingInfo?> show(BuildContext context) {
    return Navigator.of(context).push<PeerPairingInfo>(
      MaterialPageRoute(
        builder: (_) => const StorageImportScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<StorageImportScannerScreen> createState() =>
      _StorageImportScannerScreenState();
}

class _StorageImportScannerScreenState extends State<StorageImportScannerScreen> {
  MobileScannerController? _controller;
  final _pasteController = TextEditingController();
  bool _processing = false;
  String? _error;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (!_isDesktop) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
    }
  }

  @override
  void dispose() {
    _pasteController.dispose();
    final ctrl = _controller;
    if (ctrl != null) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  void _accept(PeerPairingInfo info) {
    if (_processing) return;
    setState(() => _processing = true);
    unawaited(_controller?.stop());
    Navigator.of(context).pop(info);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      final info = PeerPairingInfo.tryParse(value);
      if (info == null) continue;
      _accept(info);
      return;
    }
  }

  Future<void> _submitPaste() async {
    final l10n = AppLocalizations.of(context);
    final raw = _pasteController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.peerManual_emptyError);
      return;
    }
    final info = PeerPairingInfo.tryParse(raw);
    if (info == null) {
      setState(() => _error = l10n.peerManual_invalidError);
      return;
    }
    _accept(info);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() {
        _pasteController.text = text;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.storage_importScanTitle)),
      body: _isDesktop ? _buildPasteBody(l10n, colorScheme) : _buildScanBody(l10n, colorScheme),
    );
  }

  Widget _buildPasteBody(AppLocalizations l10n, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.storage_importPasteHint,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _pasteController,
            maxLines: 4,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'shepaw://peer?...',
              errorText: _error,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _pasteClipboard,
                icon: const Icon(Icons.content_paste, size: 18),
                label: Text(l10n.storage_importPaste),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _processing ? null : _submitPaste,
                child: Text(l10n.common_confirm),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanBody(AppLocalizations l10n, ColorScheme colorScheme) {
    return Stack(
      children: [
        if (_controller != null)
          MobileScanner(
            controller: _controller!,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) {
              return Center(
                child: Text(l10n.peerScan_cameraError('${error.errorCode}')),
              );
            },
          ),
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        Positioned(
          top: 24,
          left: 16,
          right: 16,
          child: Text(
            l10n.storage_importScanHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
          ),
        ),
        Positioned(
          bottom: 32,
          left: 24,
          right: 24,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white70),
            ),
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                builder: (ctx) => Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: _pasteController,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: 'shepaw://peer?...',
                          errorText: _error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _submitPaste();
                        },
                        child: Text(l10n.storage_importPaste),
                      ),
                    ],
                  ),
                ),
              );
            },
            icon: const Icon(Icons.link),
            label: Text(l10n.storage_importPaste),
          ),
        ),
      ],
    );
  }
}
