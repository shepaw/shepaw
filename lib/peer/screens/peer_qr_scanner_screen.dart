import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../services/peer_pairing_service.dart';

/// P2P 配对 QR 扫描页面（Initiator 侧）
class PeerQrScannerScreen extends StatefulWidget {
  final void Function(PairedPeer peer)? onPaired;

  const PeerQrScannerScreen({super.key, this.onPaired});

  @override
  State<PeerQrScannerScreen> createState() => _PeerQrScannerScreenState();
}

class _PeerQrScannerScreenState extends State<PeerQrScannerScreen> {
  MobileScannerController? _controller;
  bool _processing = false;
  String? _error;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _initScanner();
  }

  @override
  void dispose() {
    final ctrl = _controller;
    if (ctrl != null) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  void _initScanner() {
    // 桌面平台不支持摄像头扫描
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return;
    }
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      // 尝试解析为 P2P 配对 QR
      final info = PeerPairingInfo.tryParse(value);
      if (info == null) continue;

      setState(() => _processing = true);
      await _controller?.stop();

      await _doPairing(info);
      return;
    }
  }

  Future<void> _doPairing(PeerPairingInfo info) async {
    setState(() => _statusMessage = '正在连接...');

    // 短延迟后切换为"等待确认"提示
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _processing && _error == null) {
        setState(() => _statusMessage = '等待对方确认...');
      }
    });

    try {
      final peer = await PeerPairingService.instance.requestPairing(info);
      if (mounted) {
        setState(() => _statusMessage = '配对成功!');
        await Future.delayed(const Duration(milliseconds: 500));
        widget.onPaired?.call(peer);
      }
    } on PairingRejectedException {
      if (mounted) {
        setState(() {
          _error = '对方拒绝了配对请求';
          _processing = false;
          _statusMessage = null;
        });
        _restartScanner();
      }
    } on PairingTimeoutException {
      if (mounted) {
        setState(() {
          _error = '配对超时，请重试';
          _processing = false;
          _statusMessage = null;
        });
        _restartScanner();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '配对失败: $e';
          _processing = false;
          _statusMessage = null;
        });
        _restartScanner();
      }
    }
  }

  void _restartScanner() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _error = null);
        _controller?.start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 桌面平台不支持
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_mac_outlined, size: 48, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text('桌面端暂不支持摄像头扫描'),
              const SizedBox(height: 8),
              Text(
                '请在移动设备上使用扫码功能',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    // 正在处理
    if (_processing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _statusMessage ?? '处理中...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        // 扫描视图
        if (_controller != null)
          MobileScanner(
            controller: _controller!,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error, size: 48, color: colorScheme.error),
                    const SizedBox(height: 16),
                    Text('摄像头错误: ${error.errorCode}'),
                  ],
                ),
              );
            },
          ),

        // 扫描框覆盖层
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

        // 顶部提示
        Positioned(
          top: 40,
          left: 0,
          right: 0,
          child: Text(
            '将对方的二维码放入框内',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Colors.white,
              shadows: [const Shadow(blurRadius: 4, color: Colors.black54)],
            ),
          ),
        ),

        // 错误提示
        if (_error != null)
          Positioned(
            bottom: 100,
            left: 32,
            right: 32,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          ),
      ],
    );
  }
}
