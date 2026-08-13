import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'session_unread_badge.dart';

/// Unified helper for agent/group chat overflow menus.
class ChatMenuHelper {
  ChatMenuHelper._();

  static PopupMenuItem<String> _buildMenuItem({
    required String value,
    required IconData icon,
    required String label,
    Widget? trailing,
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  static List<PopupMenuEntry<String>> _sessionActionItems(
    AppLocalizations menuL10n, {
    required bool includeReset,
    int sessionUnreadCount = 0,
  }) {
    return [
      _buildMenuItem(
        value: 'newSession',
        icon: Icons.add,
        label: menuL10n.chat_newSession,
      ),
      _buildMenuItem(
        value: 'sessionHistory',
        icon: Icons.history,
        label: menuL10n.chat_sessionHistory,
        trailing: sessionUnreadCount > 0
            ? SessionUnreadBadge(count: sessionUnreadCount)
            : null,
      ),
      if (includeReset)
        _buildMenuItem(
          value: 'reset',
          icon: Icons.refresh,
          label: menuL10n.chat_resetSession,
        ),
      const PopupMenuDivider(),
    ];
  }

  /// DM agent overflow menu entries.
  ///
  /// When [sessionActionsInMenu] is true (mobile), 新建会话 / 会话历史 / 重置会话
  /// appear at the top; the title bar session button is hidden.
  static List<PopupMenuEntry<String>> agentMenuItems(
    BuildContext context, {
    bool sessionActionsInMenu = false,
    int sessionUnreadCount = 0,
    VoidCallback? onEdit,
    VoidCallback? onWorkflow,
  }) {
    final menuL10n = AppLocalizations.of(context);

    return [
      if (sessionActionsInMenu)
        ..._sessionActionItems(
          menuL10n,
          includeReset: true,
          sessionUnreadCount: sessionUnreadCount,
        )
      else ...[
        _buildMenuItem(
          value: 'reset',
          icon: Icons.refresh,
          label: menuL10n.chat_resetSession,
        ),
        const PopupMenuDivider(),
      ],
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
        value: 'storageSpace',
        icon: Icons.inventory_2_outlined,
        label: menuL10n.chat_storageSpace,
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
    required VoidCallback onNewSession,
    required VoidCallback onSessionHistory,
    required VoidCallback onViewDetails,
    required VoidCallback onStorageSpace,
    required VoidCallback onSearch,
    VoidCallback? onEdit,
    VoidCallback? onWorkflow,
  }) {
    switch (value) {
      case 'newSession':
        onNewSession();
      case 'sessionHistory':
        onSessionHistory();
      case 'edit':
        onEdit?.call();
      case 'reset':
        onReset();
      case 'details':
        onViewDetails();
      case 'storageSpace':
        onStorageSpace();
      case 'workflow':
        onWorkflow?.call();
      case 'search':
        onSearch();
    }
  }

  /// Group chat overflow menu entries.
  static List<PopupMenuEntry<String>> groupMenuItems(
    BuildContext context, {
    bool sessionActionsInMenu = false,
    int sessionUnreadCount = 0,
    VoidCallback? onWorkflow,
  }) {
    final menuL10n = AppLocalizations.of(context);

    return [
      if (sessionActionsInMenu)
        ..._sessionActionItems(
          menuL10n,
          includeReset: false,
          sessionUnreadCount: sessionUnreadCount,
        ),
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
        value: 'storageSpace',
        icon: Icons.inventory_2_outlined,
        label: menuL10n.chat_storageSpace,
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
    required VoidCallback onNewSession,
    required VoidCallback onSessionHistory,
    required VoidCallback onStorageSpace,
    required VoidCallback onSearch,
    VoidCallback? onWorkflow,
  }) {
    switch (value) {
      case 'newSession':
        onNewSession();
      case 'sessionHistory':
        onSessionHistory();
      case 'editGroup':
        onEditGroup();
      case 'members':
        onShowMembers();
      case 'storageSpace':
        onStorageSpace();
      case 'workflow':
        onWorkflow?.call();
      case 'search':
        onSearch();
    }
  }
}
