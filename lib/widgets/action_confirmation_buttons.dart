import 'package:flutter/material.dart';

/// Widget that renders action confirmation buttons inline in a message bubble.
///
/// Displays a list of buttons based on action data from the agent.
/// Once a button is selected, it shows as highlighted with a checkmark,
/// and all other buttons are greyed out and disabled.
class ActionConfirmationButtons extends StatelessWidget {
  final Map<String, dynamic> actionData;
  final void Function(String confirmationId, String actionId, String actionLabel)? onActionSelected;

  const ActionConfirmationButtons({
    Key? key,
    required this.actionData,
    this.onActionSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final prompt = actionData['prompt'] as String?;
    final actions = (actionData['actions'] as List<dynamic>?) ?? [];
    final confirmationId = actionData['confirmation_id'] as String? ?? '';
    final selectedActionId = actionData['selected_action_id'] as String?;

    if (actions.isEmpty) return const SizedBox.shrink();

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
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: actions.map<Widget>((action) {
            final actionMap = action as Map<String, dynamic>;
            final id = actionMap['id'] as String? ?? '';
            final label = actionMap['label'] as String? ?? '';
            final style = actionMap['style'] as String? ?? 'secondary';
            final isSelected = selectedActionId == id;
            final isDisabled = selectedActionId != null && !isSelected;

            return _buildButton(
              context,
              id: id,
              label: label,
              style: style,
              isSelected: isSelected,
              isDisabled: isDisabled,
              confirmationId: confirmationId,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildButton(
    BuildContext context, {
    required String id,
    required String label,
    required String style,
    required bool isSelected,
    required bool isDisabled,
    required String confirmationId,
  }) {
    if (isSelected) {
      return ElevatedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check, size: 16),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          disabledBackgroundColor: Theme.of(context).primaryColor.withOpacity(0.8),
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }

    if (isDisabled) {
      return OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          disabledForegroundColor: Colors.grey[400],
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: const TextStyle(fontSize: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          side: BorderSide(color: Colors.grey[300]!),
        ),
        child: Text(label),
      );
    }

    // Active buttons (no selection yet)
    final onTap = onActionSelected != null
        ? () => onActionSelected!(confirmationId, id, label)
        : null;

    switch (style) {
      case 'primary':
        return ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(label),
        );
      case 'danger':
        return ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(label),
        );
      default: // secondary
        return OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).primaryColor,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            side: BorderSide(color: Theme.of(context).primaryColor),
          ),
          child: Text(label),
        );
    }
  }
}
