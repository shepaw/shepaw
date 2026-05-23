import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import 'peer_pairing_confirm_screen.dart';

/// 展示自己的配对 QR 码（Responder 侧）
class PeerQrDisplayScreen extends StatefulWidget {
  final void Function(PairedPeer peer)? onPaired;

  const PeerQrDisplayScreen({super.key, this.onPaired});

  @override
  State<PeerQrDisplayScreen> createState() => _PeerQrDisplayScreenState();
}

class _PeerQrDisplayScreenState extends State<PeerQrDisplayScreen> {
  String? _qrData;
  String? _pairingCode;
  String? _error;
  bool _loading = true;
  StreamSubscription? _requestSub;

  @override
  void initState() {
    super.initState();
    _startPairing();
  }

  @override
  void dispose() {
    _requestSub?.cancel();
    PeerPairingService.instance.cancelPairing();
    super.dispose();
  }

  Future<void> _startPairing() async {
    // 取消旧的监听，避免重复订阅导致多次弹窗
    _requestSub?.cancel();
    _requestSub = null;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final qrData = await PeerPairingService.instance.startPairing();

      // 提取配对码（从 QR 数据中解析）
      final uri = Uri.parse(qrData);
      final code = uri.queryParameters['code'] ?? '';

      if (mounted) {
        setState(() {
          _qrData = qrData;
          _pairingCode = code;
          _loading = false;
        });
      }

      // 监听配对请求（仅一个订阅）
      _requestSub = PeerPairingService.instance.incomingPairingRequests.listen(
        (request) async {
          if (!mounted) return;
          // 弹出确认对话框
          final peer = await PeerPairingConfirmScreen.show(context, request);
          if (peer != null) {
            widget.onPaired?.call(peer);
          } else {
            // 被拒绝或取消，重新开始配对
            _startPairing();
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                '无法启动配对',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _startPairing,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            '让对方扫描此二维码完成配对',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),

          // QR 码
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: QrImageView(
              data: _qrData!,
              version: QrVersions.auto,
              size: 240,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),

          const SizedBox(height: 24),

          // 配对码
          if (_pairingCode != null) ...[
            Text(
              '配对码',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _pairingCode!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配对码已复制')),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _pairingCode!,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 32),

          // 状态提示
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '等待对方扫描...',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Text(
            '二维码 5 分钟内有效',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
