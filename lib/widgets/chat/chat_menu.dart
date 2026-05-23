import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Unified helper for showing agent/group chat menus.
///
/// Merges the previously duplicate desktop/mobile menu code into a single method.
class ChatMenuHelper {
  ChatMenuHelper._();

  /// Show the DM agent menu (reset, details, system prompt, search).
  static Future<void> showAgentMenu(
    BuildContext context, {
    required VoidCallback onReset,
    required VoidCallback onViewDetails,
    required VoidCallback onSearch,
    required VoidCallback onCustomSystemPrompt,
    VoidCallback? onEdit,
  }) async {
    final menuL10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final screenSize = overlay.size;

    final position = RelativeRect.fromLTRB(
      screenSize.width - 280,
      kToolbarHeight + MediaQuery.of(context).padding.top,
      0,
      0,
    );

    final value = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 280),
      items: [
        PopupMenuItem(value: 'reset', child: ListTile(dense: true, leading: const Icon(Icons.refresh), title: Text(menuL10n.chat_resetSession))),
        const PopupMenuDivider(),
        if (onEdit != null)
          PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: const Icon(Icons.edit_outlined), title: Text(menuL10n.chat_editAgent))),
        PopupMenuItem(value: 'details', child: ListTile(dense: true, leading: const Icon(Icons.info_outline), title: Text(menuL10n.chat_viewDetails))),
        PopupMenuItem(value: 'systemPrompt', child: ListTile(dense: true, leading: const Icon(Icons.edit_note), title: Text(menuL10n.chat_customSystemPrompt))),
        PopupMenuItem(value: 'search', child: ListTile(dense: true, leading: const Icon(Icons.search), title: Text(menuL10n.chat_searchMessages))),
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
    required VoidCallback onEditGroup,
    required VoidCallback onShowMembers,
    required VoidCallback onAddMember,
    required VoidCallback onSearch,
    VoidCallback? onWorkflow,
  }) async {
    final menuL10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final screenSize = overlay.size;

    final position = RelativeRect.fromLTRB(
      screenSize.width - 280,
      kToolbarHeight + MediaQuery.of(context).padding.top,
      0,
      0,
    );

    final value = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 280),
      items: [
        PopupMenuItem(value: 'editGroup', child: ListTile(dense: true, leading: const Icon(Icons.edit), title: Text(menuL10n.chat_editGroupInfo))),
        PopupMenuItem(value: 'members', child: ListTile(dense: true, leading: const Icon(Icons.group), title: Text(menuL10n.chat_groupMembers))),
        PopupMenuItem(value: 'addMember', child: ListTile(dense: true, leading: const Icon(Icons.person_add), title: Text(menuL10n.chat_addMember))),
        if (onWorkflow != null)
          PopupMenuItem(value: 'workflow', child: ListTile(dense: true, leading: const Icon(Icons.account_tree_outlined), title: Text(menuL10n.chat_workflow))),
        PopupMenuItem(value: 'search', child: ListTile(dense: true, leading: const Icon(Icons.search), title: Text(menuL10n.chat_searchMessages))),
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
