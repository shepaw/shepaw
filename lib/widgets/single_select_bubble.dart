import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../utils/interaction_payload.dart';
import 'interaction_closed_hint.dart';

/// Widget that renders a single-select (radio) list inline in a message bubble.
///
/// Displays a prompt and a vertical list of radio-style options.
/// Once confirmed, the selected option is highlighted with a checkmark,
/// and all other options are greyed out and disabled.
class SingleSelectBubble extends StatefulWidget {
  final Map<String, dynamic> selectData;
  final void Function(String selectId, String optionId, String optionLabel)? onSelectSubmitted;

  const SingleSelectBubble({
    Key? key,
    required this.selectData,
    this.onSelectSubmitted,
  }) : super(key: key);

  @override
  State<SingleSelectBubble> createState() => _SingleSelectBubbleState();
}

class _SingleSelectBubbleState extends State<SingleSelectBubble> {
  String? _tempSelectedId;

  @override
  Widget build(BuildContext context) {
    final prompt = widget.selectData['prompt'] as String?;
    final options = interactionOptions(widget.selectData['options']);
    final selectId = interactionSelectId(widget.selectData);
    final confirmedOptionId = widget.selectData['selected_option_id'] as String?;
    final isConfirmed = confirmedOptionId != null;
    // 主机不再等这张卡了。答过的优先：作答和作废是两条会先后脚到的消息。
    final closedReason = widget.selectData['closed'] as String?;
    final isClosed = closedReason != null && !isConfirmed;

    if (options.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt != null && prompt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              prompt,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.54),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ...options.map<Widget>((option) {
          final id = option.id;
          // 作废时忽略本地那次未提交的点击 —— 它没送出去，不该看着像选了。
          final isSelected = isConfirmed
              ? confirmedOptionId == id
              : (!isClosed && _tempSelectedId == id);
          final isDisabled = isClosed || (isConfirmed && confirmedOptionId != id);

          return _buildOptionRow(
            context,
            id: id,
            label: option.label,
            isSelected: isSelected,
            isDisabled: isDisabled,
            isConfirmed: isConfirmed,
          );
        }),
        const SizedBox(height: 8),
        if (isClosed)
          InteractionClosedHint(reason: closedReason)
        else if (!isConfirmed)
          _buildConfirmButton(context, selectId, options),
      ],
    );
  }

  Widget _buildOptionRow(
    BuildContext context, {
    required String id,
    required String label,
    required bool isSelected,
    required bool isDisabled,
    required bool isConfirmed,
  }) {
    return GestureDetector(
      onTap: (isConfirmed || isDisabled)
          ? null
          : () {
              setState(() {
                _tempSelectedId = id;
              });
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor.withOpacity(0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).primaryColor.withOpacity(0.3)
                : Colors.grey[300]!,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            if (isConfirmed && isSelected)
              Icon(Icons.check_circle, size: 20, color: Theme.of(context).primaryColor)
            else if (isConfirmed && isDisabled)
              Icon(Icons.radio_button_off, size: 20, color: Colors.grey[300])
            else if (isSelected)
              Icon(Icons.radio_button_checked, size: 20, color: Theme.of(context).primaryColor)
            else
              Icon(Icons.radio_button_off, size: 20, color: Colors.grey[400]),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: isDisabled
                      ? Colors.grey[400]
                      : Theme.of(context).colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmButton(
    BuildContext context,
    String selectId,
    List<InteractionOption> options,
  ) {
    final hasSelection = _tempSelectedId != null;
    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton(
        onPressed: hasSelection
            ? () {
                final selectedOption = options.firstWhere(
                  (o) => o.id == _tempSelectedId,
                  orElse: () => const InteractionOption(id: '', label: ''),
                );
                widget.onSelectSubmitted?.call(
                  selectId,
                  _tempSelectedId!,
                  selectedOption.label,
                );
              }
            : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey[300],
          disabledForegroundColor: Colors.grey[500],
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(AppLocalizations.of(context).widget_confirm),
      ),
    );
  }
}
