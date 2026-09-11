import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/pairing_payload.dart';

/// 每 4 位插一个空格，便于逐段核对指纹。
String formatPairingFingerprint(String fp) {
  final buffer = StringBuffer();
  for (var i = 0; i < fp.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(fp[i]);
  }
  return buffer.toString();
}

/// 配对前的确认卡片：把「即将连上的是谁」摊开给用户核对。
///
/// 「我连它」下的三条路径（扫码、填对方 Hub 地址、粘贴配对链接）共用这一张卡。
/// 共用不是为了省代码 —— 卡里的两条安全文案（名字未经认证、指纹才是凭据）
/// 是这个功能的信任边界，抄成三份必然会漂移。
///
/// [extraRows] 追加在端点行之后（Hub 路径用它展示 Hub 地址），
/// [warnings] 追加在信息容器与错误之间（Hub 路径用它声明「对方不会二次确认」
/// 与「令牌会明文发送」）。
class PeerPairingConfirmCard extends StatelessWidget {
  const PeerPairingConfirmCard({
    super.key,
    required this.info,
    required this.onConfirm,
    required this.onCancel,
    this.confirmLabel,
    this.error,
    this.extraRows = const [],
    this.warnings = const [],
  });

  final PeerPairingInfo info;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  /// 确认按钮文案，默认「确认并配对」。
  final String? confirmLabel;

  /// 上一次尝试的失败原因。非空时渲染在卡片内，重试只需再点一次确认。
  final String? error;

  final List<Widget> extraRows;
  final List<Widget> warnings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final name = info.displayName;
    final isLocal = info.mode == PeerConnectMode.local;
    final endpoint = isLocal ? info.localEndpoint! : info.channelEndpoint!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.help_outline, size: 48, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            l10n.peerManual_confirmTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      name != null ? Icons.devices_other : Icons.help_outline,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        name != null
                            ? l10n.peerManual_targetName(name)
                            : l10n.peerManual_targetNameUnknown,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                // 安全边界：名字是对方自填的。文案不能弱化。
                if (name != null) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 36),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l10n.peerManual_targetNameUnverified,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // 指纹才是可核对、可信任的值，所以做成可选中复制。
                PeerPairingInfoRow(
                  icon: Icons.fingerprint,
                  child: SelectableText(
                    l10n.peerManual_fingerprint(
                      formatPairingFingerprint(info.fingerprint),
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(height: 12),
                PeerPairingInfoRow(
                  icon: isLocal ? Icons.lan_outlined : Icons.cloud_outlined,
                  child: Text(
                    isLocal
                        ? l10n.peerManual_viaLocal(endpoint)
                        : l10n.peerManual_viaChannel(endpoint),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                ...extraRows,
              ],
            ),
          ),
          ...warnings,
          if (error != null) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 20, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.link),
            label: Text(confirmLabel ?? l10n.peerManual_confirmConnect),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onCancel,
            child: Text(l10n.peerManual_cancel),
          ),
        ],
      ),
    );
  }
}

/// 卡片里的一行「图标 + 内容」。公开是为了让调用方在 [extraRows] 里补的行
/// 与内置行长得一模一样 —— 视觉语言不统一比少一行更糟。
class PeerPairingInfoRow extends StatelessWidget {
  const PeerPairingInfoRow({
    super.key,
    required this.icon,
    required this.child,
  });

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    );
  }
}
