import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Unified helper for agent/group chat overflow menus.
class ChatMenuHelper {
  ChatMenuHelper._();

  static PopupMenuItem<String> _buildMenuItem({
    required String value,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  /// DM agent overflow menu entries.
  ///
  /// [onCustomSystemPrompt] is omitted for peer agents (relay does not forward it).
  static List<PopupMenuEntry<String>> agentMenuItems(
    BuildContext context, {
    VoidCallback? onCustomSystemPrompt,
    VoidCallback? onEdit,
    VoidCallback? onWorkflow,
  }) {
    final menuL10n = AppLocalizations.of(context);

    return [
      _buildMenuItem(
        value: 'reset',
        icon: Icons.refresh,
        label: menuL10n.chat_resetSession,
      ),
      const PopupMenuDivider(),
      if (onEdit != null)
        _buildMenuItem(
          value: 'edit',
          icon: Icons.edit_outlined,
          label: menuL10n.chat_editAgent,
        ),
      _buildMenuItem(
        value: 'details',
        icon: Icons.info_outline,
        label: menuL10n.chat_viewDetails,
      ),
      if (onCustomSystemPrompt != null)
        _buildMenuItem(
          value: 'systemPrompt',
          icon: Icons.edit_note_outlined,
          label: menuL10n.chat_customSystemPrompt,
        ),
      if (onWorkflow != null)
        _buildMenuItem(
          value: 'workflow',
          icon: Icons.account_tree_outlined,
          label: menuL10n.chat_workflow,
        ),
      _buildMenuItem(
        value: 'search',
        icon: Icons.search,
        label: menuL10n.chat_searchMessages,
      ),
    ];
  }

  static void handleAgentMenuSelection(
    String value, {
    required VoidCallback onReset,
    required VoidCallback onViewDetails,
    required VoidCallback onSearch,
    VoidCallback? onCustomSystemPrompt,
    VoidCallback? onEdit,
    VoidCallback? onWorkflow,
  }) {
    switch (value) {
      case 'edit':
        onEdit?.call();
      case 'reset':
        onReset();
      case 'details':
        onViewDetails();
      case 'systemPrompt':
        onCustomSystemPrompt?.call();
      case 'workflow':
        onWorkflow?.call();
      case 'search':
        onSearch();
    }
  }

  /// Group chat overflow menu entries.
  static List<PopupMenuEntry<String>> groupMenuItems(
    BuildContext context, {
    VoidCallback? onWorkflow,
  }) {
    final menuL10n = AppLocalizations.of(context);

    return [
      _buildMenuItem(
        value: 'editGroup',
        icon: Icons.edit_outlined,
        label: menuL10n.chat_editGroupInfo,
      ),
      _buildMenuItem(
        value: 'members',
        icon: Icons.group_outlined,
        label: menuL10n.chat_groupMembers,
      ),
      if (onWorkflow != null)
        _buildMenuItem(
          value: 'workflow',
          icon: Icons.account_tree_outlined,
          label: menuL10n.chat_workflow,
        ),
      _buildMenuItem(
        value: 'search',
        icon: Icons.search,
        label: menuL10n.chat_searchMessages,
      ),
    ];
  }

  static void handleGroupMenuSelection(
    String value, {
    required VoidCallback onEditGroup,
    required VoidCallback onShowMembers,
    required VoidCallback onSearch,
    VoidCallback? onWorkflow,
  }) {
    switch (value) {
      case 'editGroup':
        onEditGroup();
      case 'members':
        onShowMembers();
      case 'workflow':
        onWorkflow?.call();
      case 'search':
        onSearch();
    }
  }
}
