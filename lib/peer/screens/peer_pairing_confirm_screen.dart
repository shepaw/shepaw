import 'package:flutter/material.dart';

import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import '../services/peer_storage_service.dart';
import '../widgets/peer_agent_share_dialog.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';

/// 配对确认弹窗（Responder 侧）
///
/// 当对方扫描 QR 码后，显示对方设备信息；用户可同时选择要分享的 Agent，确认后完成配对。
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
  bool _loadingAgents = true;
  List<PeerShareAgentEntry> _shareAgents = [];
  Map<String, bool> _selectedShares = {};

  @override
  void initState() {
    super.initState();
    _loadShareableAgents();
  }

  Future<void> _loadShareableAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final eligible = all
          .where((a) => a.isLocal && a.allowExternalAccess)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      final existingPeer =
          await PeerStorageService().getPeerByFingerprint(widget.request.fingerprint);
      final saved = existingPeer != null
          ? await PeerStorageService().getAgentShares(existingPeer.id)
          : <String, bool>{};
      final hasSaved = saved.isNotEmpty;

      final entries = eligible
          .map((a) => PeerShareAgentEntry.fromAgent(
                a,
                initiallyShared: _initiallyShared(a.id, saved, hasSaved),
              ))
          .toList();

      if (mounted) {
        setState(() {
          _shareAgents = entries;
          _selectedShares = {
            for (final e in entries) e.id: e.initiallyShared,
          };
          _loadingAgents = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingAgents = false);
    }
  }

  bool _initiallyShared(String agentId, Map<String, bool> saved, bool hasSaved) {
    if (!hasSaved) return true;
    return saved[agentId] ?? true;
  }

  Future<void> _confirm() async {
    setState(() => _processing = true);
    try {
      final agentShares = _shareAgents.isEmpty ? null : _selectedShares;
      final peer = await PeerPairingService.instance.confirmPairing(
        widget.request,
        agentShares: agentShares,
      );
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
    final sharedCount = _selectedShares.values.where((v) => v).length;

    return AlertDialog(
      icon: Icon(
        Icons.devices_other,
        size: 40,
        color: colorScheme.primary,
      ),
      title: const Text('配对请求'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                    Row(
                      children: [
                        Icon(Icons.fingerprint,
                            size: 20, color: colorScheme.onSurfaceVariant),
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

              if (_loadingAgents) ...[
                const SizedBox(height: 16),
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ] else if (_shareAgents.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  '选择要分享给该设备的 Agent',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '对方将能通过配对连接使用你选中的 Agent（需已开启「允许外部访问」）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                PeerAgentShareSelector(
                  agents: _shareAgents,
                  initialSelection: _selectedShares,
                  onChanged: (shares) => setState(() => _selectedShares = shares),
                ),
              ] else ...[
                const SizedBox(height: 16),
                Text(
                  '确认配对后，双方可以直接通讯',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ),
        ),
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
              : Text(_shareAgents.isEmpty
                  ? '确认配对'
                  : (sharedCount > 0 ? '确认配对 ($sharedCount)' : '确认配对')),
        ),
      ],
    );
  }

  String _formatFingerprint(String fp) {
    final buffer = StringBuffer();
    for (var i = 0; i < fp.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(fp[i]);
    }
    return buffer.toString();
  }
}
