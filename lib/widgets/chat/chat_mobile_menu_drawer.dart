import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Mobile chat side menu — slides in from the right.
///
/// Mirrors [ChatMenuHelper] popup items as list tiles, opened from the
/// app-bar more button on mobile.
class ChatMobileMenuDrawer extends StatelessWidget {
  final bool isGroupMode;
  final String title;

  final VoidCallback onShowSessionList;

  final VoidCallback? onResetSession;
  final VoidCallback? onViewDetails;
  final VoidCallback? onEditAgent;
  final VoidCallback onSearch;
  final VoidCallback? onCustomSystemPrompt;

  final VoidCallback? onEditGroup;
  final VoidCallback? onShowMembers;
  final VoidCallback? onAddMember;
  final VoidCallback? onWorkflow;

  const ChatMobileMenuDrawer({
    super.key,
    required this.isGroupMode,
    required this.title,
    required this.onShowSessionList,
    this.onResetSession,
    this.onViewDetails,
    this.onEditAgent,
    required this.onSearch,
    this.onCustomSystemPrompt,
    this.onEditGroup,
    this.onShowMembers,
    this.onAddMember,
    this.onWorkflow,
  });

  void _closeThen(BuildContext context, VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              color: colorScheme.surfaceContainerHighest,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(l10n.chat_sessionList),
                    onTap: () => _closeThen(context, onShowSessionList),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  if (isGroupMode) ...[
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l10n.chat_editGroupInfo),
                      onTap: () => _closeThen(context, onEditGroup!),
                    ),
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: Text(l10n.chat_groupMembers),
                      onTap: () => _closeThen(context, onShowMembers!),
                    ),
                    ListTile(
                      leading: const Icon(Icons.person_add_outlined),
                      title: Text(l10n.chat_addMember),
                      onTap: () => _closeThen(context, onAddMember!),
                    ),
                    if (onWorkflow != null)
                      ListTile(
                        leading: const Icon(Icons.account_tree_outlined),
                        title: Text(l10n.chat_workflow),
                        onTap: () => _closeThen(context, onWorkflow!),
                      ),
                    ListTile(
                      leading: const Icon(Icons.search),
                      title: Text(l10n.chat_searchMessages),
                      onTap: () => _closeThen(context, onSearch),
                    ),
                  ] else ...[
                    ListTile(
                      leading: const Icon(Icons.refresh),
                      title: Text(l10n.chat_resetSession),
                      onTap: () => _closeThen(context, onResetSession!),
                    ),
                    if (onEditAgent != null)
                      ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(l10n.chat_editAgent),
                        onTap: () => _closeThen(context, onEditAgent!),
                      ),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(l10n.chat_viewDetails),
                      onTap: () => _closeThen(context, onViewDetails!),
                    ),
                    ListTile(
                      leading: const Icon(Icons.edit_note_outlined),
                      title: Text(l10n.chat_customSystemPrompt),
                      onTap: () => _closeThen(context, onCustomSystemPrompt!),
                    ),
                    ListTile(
                      leading: const Icon(Icons.search),
                      title: Text(l10n.chat_searchMessages),
                      onTap: () => _closeThen(context, onSearch),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
