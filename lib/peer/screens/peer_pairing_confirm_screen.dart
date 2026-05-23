import 'package:flutter/material.dart';

import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';

/// 配对确认弹窗（Responder 侧）
///
/// 当对方扫描 QR 码后，显示对方设备信息，用户确认后完成配对。
class PeerPairingConfirmScreen extends StatefulWidget {
  final IncomingPairingRequest request;

  const PeerPairingConfirmScreen({super.key, required this.request});

  /// 弹出确认对话框，返回配对成功的 PairedPeer 或 null（拒绝/取消）
  static Future<PairedPeer?> show(
    BuildContext context,
    IncomingPairingRequest request,
  ) {
    return showDialog<PairedPeer?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PeerPairingConfirmScreen(request: request),
    );
  }

  @override
  State<PeerPairingConfirmScreen> createState() => _PeerPairingConfirmScreenState();
}

class _PeerPairingConfirmScreenState extends State<PeerPairingConfirmScreen> {
  bool _processing = false;

  Future<void> _confirm() async {
    setState(() => _processing = true);
    try {
      final peer = await PeerPairingService.instance.confirmPairing(widget.request);
      if (mounted) {
        Navigator.of(context).pop(peer);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('配对失败: $e')),
        );
      }
    }
  }

  Future<void> _reject() async {
    await PeerPairingService.instance.rejectPairing(widget.request);
    if (mounted) {
      Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      icon: Icon(
        Icons.devices_other,
        size: 40,
        color: colorScheme.primary,
      ),
      title: const Text('配对请求'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '以下设备想要与你配对：',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // 设备信息卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                // 设备名称
                Row(
                  children: [
                    Icon(Icons.smartphone, color: colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.request.deviceName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 指纹
                Row(
                  children: [
                    Icon(Icons.fingerprint, size: 20, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Text(
                      _formatFingerprint(widget.request.fingerprint),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Text(
            '确认配对后，双方可以直接通讯',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _processing ? null : _reject,
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: _processing ? null : _confirm,
          child: _processing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认配对'),
        ),
      ],
    );
  }

  String _formatFingerprint(String fp) {
    // 每 4 字符加空格：8f3a1b2c → 8f3a 1b2c
    final buffer = StringBuffer();
    for (var i = 0; i < fp.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(fp[i]);
    }
    return buffer.toString();
  }
}
