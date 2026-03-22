import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

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
    final options = (widget.selectData['options'] as List<dynamic>?) ?? [];
    final selectId = widget.selectData['select_id'] as String? ?? '';
    final confirmedOptionId = widget.selectData['selected_option_id'] as String?;
    final isConfirmed = confirmedOptionId != null;

    if (options.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt != null && prompt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              prompt,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ...options.map<Widget>((option) {
          final optionMap = option as Map<String, dynamic>;
          final id = optionMap['id'] as String? ?? '';
          final label = optionMap['label'] as String? ?? '';

          final isSelected = isConfirmed
              ? confirmedOptionId == id
              : _tempSelectedId == id;
          final isDisabled = isConfirmed && confirmedOptionId != id;

          return _buildOptionRow(
            context,
            id: id,
            label: label,
            isSelected: isSelected,
            isDisabled: isDisabled,
            isConfirmed: isConfirmed,
          );
        }),
        const SizedBox(height: 8),
        if (!isConfirmed)
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
      onTap: isConfirmed
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
                  color: isDisabled ? Colors.grey[400] : Colors.black87,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmButton(BuildContext context, String selectId, List<dynamic> options) {
    final hasSelection = _tempSelectedId != null;
    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton(
        onPressed: hasSelection
            ? () {
                final selectedOption = options.firstWhere(
                  (o) => (o as Map<String, dynamic>)['id'] == _tempSelectedId,
                  orElse: () => <String, dynamic>{},
                ) as Map<String, dynamic>;
                final label = selectedOption['label'] as String? ?? '';
                widget.onSelectSubmitted?.call(selectId, _tempSelectedId!, label);
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
