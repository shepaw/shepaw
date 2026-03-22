import 'package:flutter/material.dart';

/// Widget that renders a multi-select (checkbox) list inline in a message bubble.
///
/// Displays a prompt and a vertical list of checkbox-style options.
/// User can toggle multiple options, then press "Submit" to confirm.
/// After submission, selected options are highlighted with checkmarks,
/// unselected are greyed out, and all are disabled.
class MultiSelectBubble extends StatefulWidget {
  final Map<String, dynamic> selectData;
  final void Function(String selectId, List<String> optionIds, String summary)? onSelectSubmitted;

  const MultiSelectBubble({
    Key? key,
    required this.selectData,
    this.onSelectSubmitted,
  }) : super(key: key);

  @override
  State<MultiSelectBubble> createState() => _MultiSelectBubbleState();
}

class _MultiSelectBubbleState extends State<MultiSelectBubble> {
  final Set<String> _tempSelectedIds = {};

  @override
  Widget build(BuildContext context) {
    final prompt = widget.selectData['prompt'] as String?;
    final options = (widget.selectData['options'] as List<dynamic>?) ?? [];
    final selectId = widget.selectData['select_id'] as String? ?? '';
    final confirmedIds = widget.selectData['selected_option_ids'] as List<dynamic>?;
    final isConfirmed = confirmedIds != null;
    final confirmedIdSet = isConfirmed ? confirmedIds.cast<String>().toSet() : <String>{};
    final minSelect = widget.selectData['min_select'] as int? ?? 0;
    final maxSelect = widget.selectData['max_select'] as int?;

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
              ? confirmedIdSet.contains(id)
              : _tempSelectedIds.contains(id);
          final isDisabled = isConfirmed && !confirmedIdSet.contains(id);

          return _buildOptionRow(
            context,
            id: id,
            label: label,
            isSelected: isSelected,
            isDisabled: isDisabled,
            isConfirmed: isConfirmed,
            maxSelect: maxSelect,
          );
        }),
        const SizedBox(height: 8),
        if (!isConfirmed)
          _buildSubmitButton(context, selectId, options, minSelect),
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
    int? maxSelect,
  }) {
    final atMax = maxSelect != null && _tempSelectedIds.length >= maxSelect && !_tempSelectedIds.contains(id);

    return GestureDetector(
      onTap: isConfirmed || (atMax && !isSelected)
          ? null
          : () {
              setState(() {
                if (_tempSelectedIds.contains(id)) {
                  _tempSelectedIds.remove(id);
                } else {
                  _tempSelectedIds.add(id);
                }
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
              Icon(Icons.check_box, size: 20, color: Theme.of(context).primaryColor)
            else if (isConfirmed && isDisabled)
              Icon(Icons.check_box_outline_blank, size: 20, color: Colors.grey[300])
            else if (isSelected)
              Icon(Icons.check_box, size: 20, color: Theme.of(context).primaryColor)
            else
              Icon(Icons.check_box_outline_blank, size: 20, color: Colors.grey[400]),
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

  Widget _buildSubmitButton(
    BuildContext context,
    String selectId,
    List<dynamic> options,
    int minSelect,
  ) {
    final count = _tempSelectedIds.length;
    final hasEnough = count >= minSelect;

    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton(
        onPressed: hasEnough
            ? () {
                final selectedLabels = options
                    .where((o) => _tempSelectedIds.contains((o as Map<String, dynamic>)['id']))
                    .map((o) => (o as Map<String, dynamic>)['label'] as String? ?? '')
                    .toList();
                final summary = selectedLabels.join(', ');
                widget.onSelectSubmitted?.call(
                  selectId,
                  _tempSelectedIds.toList(),
                  summary,
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
        child: Text(count > 0 ? 'Submit ($count selected)' : 'Submit'),
      ),
    );
  }
}
