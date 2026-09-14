import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/l10n_helpers.dart';
import '../../../theme/app_theme.dart';

/// 事件列表的共用行：图标 + 本地化名 + 原始标识 + 档位 chip。
///
/// 名称化只发生在渲染层：`pattern` / `type` / 线上档位值原样传给
/// [rawLabel] 与 [delivery]，便于排查时对照 CLI 输出。
class EventRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;

  /// 本地化展示名（如 `设备配对请求` / `群聊编排 · *`）。
  final String title;

  /// 原始内部标识（pattern / type / source），等宽小字展示。
  final String? rawLabel;

  /// 线上投递档位（`EventDelivery.wireValue`）；null 时不显示 chip。
  final String? delivery;

  /// 跟随 [title] 的次要信息（时间、seq、correlation…）。
  final String? meta;

  final List<Widget> trailing;
  final VoidCallback? onTap;

  /// 展开后的内容（如 payload）。
  final Widget? expanded;

  const EventRow({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor,
    this.rawLabel,
    this.delivery,
    this.meta,
    this.trailing = const [],
    this.onTap,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = iconColor ?? AppColors.primary;
    final raw = rawLabel;
    final deliveryLabel = localizeEventDelivery(l10n, delivery);
    final metaText = meta;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          ),
                          if (deliveryLabel != null) ...[
                            const SizedBox(width: 6),
                            _DeliveryChip(label: deliveryLabel),
                          ],
                        ],
                      ),
                      if (raw != null && raw.isNotEmpty)
                        // 通配 pattern 的信息量不能丢：名称化后
                        // `chat.group.*` 与 `chat.group.step.*` 同名。
                        Text(
                          raw,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.35,
                            fontFamily: 'monospace',
                            color: Colors.grey[600],
                          ),
                        ),
                      if (metaText != null && metaText.isNotEmpty)
                        Text(
                          metaText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.35,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
                ...trailing,
              ],
            ),
            if (expanded != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 4),
                child: expanded,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeliveryChip extends StatelessWidget {
  final String label;

  const _DeliveryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, height: 1.3, color: color),
      ),
    );
  }
}
