import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Unified helper for showing agent/group chat menus.
///
/// Visual style matches the home screen add-button dropdown.
class ChatMenuHelper {
  ChatMenuHelper._();

  static const double _menuWidth = 220.0;
  static const double _gap = 6.0;
  static const double _appBarActionEdgeGap = 12.0;

  static RelativeRect _menuPosition(
    BuildContext context, {
    BuildContext? anchorContext,
  }) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlay.size;

    final anchorBox = anchorContext?.findRenderObject() as RenderBox?;
    if (anchorBox != null) {
      final bottomRight = anchorBox.localToGlobal(
        anchorBox.size.bottomRight(Offset.zero),
        ancestor: overlay,
      );
      return RelativeRect.fromLTRB(
        bottomRight.dx - _menuWidth,
        bottomRight.dy + _gap,
        overlaySize.width - bottomRight.dx,
        overlaySize.height - bottomRight.dy - _gap,
      );
    }

    return RelativeRect.fromLTRB(
      overlaySize.width - _menuWidth - _appBarActionEdgeGap,
      kToolbarHeight + MediaQuery.of(context).padding.top + _gap,
      _appBarActionEdgeGap,
      0,
    );
  }

  static Future<String?> _showStyledMenu(
    BuildContext context, {
    required List<PopupMenuEntry<String>> items,
    BuildContext? anchorContext,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return showMenu<String>(
      context: context,
      position: _menuPosition(context, anchorContext: anchorContext),
      constraints: const BoxConstraints.tightFor(width: _menuWidth),
      color: colorScheme.surface,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.6)),
      ),
      items: items,
    );
  }

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

  /// Show the DM agent menu (reset, details, system prompt, search).
  static Future<void> showAgentMenu(
    BuildContext context, {
    BuildContext? anchorContext,
    required VoidCallback onReset,
    required VoidCallback onViewDetails,
    required VoidCallback onSearch,
    required VoidCallback onCustomSystemPrompt,
    VoidCallback? onEdit,
  }) async {
    final menuL10n = AppLocalizations.of(context);

    final value = await _showStyledMenu(
      context,
      anchorContext: anchorContext,
      items: [
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
        _buildMenuItem(
          value: 'systemPrompt',
          icon: Icons.edit_note_outlined,
          label: menuL10n.chat_customSystemPrompt,
        ),
        _buildMenuItem(
          value: 'search',
          icon: Icons.search,
          label: menuL10n.chat_searchMessages,
        ),
      ],
    );

    if (value == null) return;
    switch (value) {
      case 'edit':
        onEdit?.call();
      case 'reset':
        onReset();
      case 'details':
        onViewDetails();
      case 'systemPrompt':
        onCustomSystemPrompt();
      case 'search':
        onSearch();
    }
  }

  /// Show the group chat menu (edit, members, add, workflow, search).
  static Future<void> showGroupMenu(
    BuildContext context, {
    BuildContext? anchorContext,
    required VoidCallback onEditGroup,
    required VoidCallback onShowMembers,
    required VoidCallback onAddMember,
    required VoidCallback onSearch,
    VoidCallback? onWorkflow,
  }) async {
    final menuL10n = AppLocalizations.of(context);

    final value = await _showStyledMenu(
      context,
      anchorContext: anchorContext,
      items: [
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
        _buildMenuItem(
          value: 'addMember',
          icon: Icons.person_add_outlined,
          label: menuL10n.chat_addMember,
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
      ],
    );

    if (value == null) return;
    switch (value) {
      case 'editGroup':
        onEditGroup();
      case 'members':
        onShowMembers();
      case 'addMember':
        onAddMember();
      case 'workflow':
        onWorkflow?.call();
      case 'search':
        onSearch();
    }
  }
}
