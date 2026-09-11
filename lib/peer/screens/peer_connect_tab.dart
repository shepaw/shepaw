import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/platform_utils.dart';
import '../models/paired_peer.dart';
import 'peer_hub_input_screen.dart';
import 'peer_manual_input_screen.dart';
import 'peer_scan_screen.dart';

/// 「设备配对 → 我连它」的入口列表。
///
/// 这一页回答的是**方式**：同样是主动去连对方，可以扫码、可以填对方 Hub 地址、
/// 也可以粘贴对方给的链接。三种方式跑的是同一套配对握手，成功出口也都收口到
/// [onPaired]，所以这里不自己判断「是不是内嵌在桌面右栏」，交给父页面分派。
class PeerConnectTab extends StatelessWidget {
  const PeerConnectTab({super.key, required this.onPaired});

  final void Function(PairedPeer peer) onPaired;

  /// 扫码。桌面端在这里就拦掉：`mobile_scanner` 没有桌面实现，
  /// 推进去只会看到一个「不支持」的空页面。
  Future<void> _scan(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    if (isDesktopPlatform) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.peerConnect_scanDesktopHint)),
      );
      return;
    }
    final peer = await PeerScanScreen.show(context);
    if (peer != null) onPaired(peer);
  }

  Future<void> _hub(BuildContext context) async {
    final peer = await PeerHubInputScreen.show(context);
    if (peer != null) onPaired(peer);
  }

  Future<void> _paste(BuildContext context) async {
    final peer = await PeerManualInputScreen.show(context);
    if (peer != null) onPaired(peer);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ConnectTile(
          icon: Icons.qr_code_scanner,
          title: l10n.peerConnect_scanTitle,
          subtitle: l10n.peerConnect_scanSubtitle,
          onTap: () => _scan(context),
        ),
        const SizedBox(height: 8),
        _ConnectTile(
          icon: Icons.dns_outlined,
          title: l10n.peerConnect_hubTitle,
          subtitle: l10n.peerConnect_hubSubtitle,
          onTap: () => _hub(context),
        ),
        const SizedBox(height: 8),
        _ConnectTile(
          icon: Icons.link,
          title: l10n.peerConnect_pasteTitle,
          subtitle: l10n.peerConnect_pasteSubtitle,
          onTap: () => _paste(context),
        ),
        const SizedBox(height: 24),
        _buildGuideCard(context, l10n),
      ],
    );
  }

  /// 指向 Agent Hub 的安装指引卡片。
  ///
  /// 只做指路，不复制一份命令 —— 指引正文只有 [PeerHubInputScreen] 一份，
  /// 「先设 token，再说 --host 0.0.0.0」的顺序才不会在两个地方各错一次。
  Widget _buildGuideCard(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.help_outline, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.peerConnect_guideTitle,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => PeerHubInputScreen.show(
                    context,
                    showGuide: true,
                  ),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.peerConnect_guideAction),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectTile extends StatelessWidget {
  const _ConnectTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
