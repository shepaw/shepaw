import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 卡片作废时的那行小字 —— 审批卡和表单卡共用，免得两处各写一份还会走样。
///
/// 「作废」= 主机不再等这张卡了：等不到回答（`timeout`，它按最合理的默认继续
/// 往下跑了）或回合被停止（`cancelled`）。app 自己在回合结束时兜底时用
/// `turn_ended`。卡片本身留在对话里 —— 「问过但没答」这个事实值得留着 ——
/// 只是不能再点。
String interactionClosedLabel(BuildContext context, String? reason) {
  final l10n = AppLocalizations.of(context);
  switch (reason) {
    case 'timeout':
      return l10n.widget_interactionExpired;
    case 'cancelled':
      return l10n.widget_interactionCancelled;
    default:
      return l10n.widget_interactionClosed;
  }
}

class InteractionClosedHint extends StatelessWidget {
  /// `agent_interaction_closed` 帧里的 reason；未知/缺失时给一句笼统的。
  final String? reason;

  const InteractionClosedHint({Key? key, this.reason}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(Icons.hourglass_disabled_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            interactionClosedLabel(context, reason),
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
