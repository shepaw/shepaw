import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../peer/widgets/peer_source_badge.dart';
import '../../theme/app_theme.dart';
import '../../utils/layout_utils.dart';

/// Multi-select agent picker for adding members to a group chat.
///
/// On mobile, wraps content in a [Scaffold] with a confirm action in the
/// app bar. On desktop, shows a header confirm button inside the panel.
class AddGroupMemberPicker extends StatefulWidget {
  final List<RemoteAgent> availableAgents;
  final bool wrappedInScaffold;

  const AddGroupMemberPicker({
    super.key,
    required this.availableAgents,
    this.wrappedInScaffold = false,
  });

  @override
  State<AddGroupMemberPicker> createState() => _AddGroupMemberPickerState();
}

class _AddGroupMemberPickerState extends State<AddGroupMemberPicker> {
  late final Set<String> _selectedIds;
  final TextEditingController _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Default-select She when she is available to add.
    _selectedIds = {
      for (final agent in widget.availableAgents)
        if (agent.isShe) agent.id,
    };
    _filterController.addListener(_onFilterChanged);
  }

  @override
  void dispose() {
    _filterController.removeListener(_onFilterChanged);
    _filterController.dispose();
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  List<RemoteAgent> get _selectedAgents => widget.availableAgents
      .where((agent) => _selectedIds.contains(agent.id))
      .toList();

  List<RemoteAgent> get _filteredAgents {
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) return widget.availableAgents;
    return widget.availableAgents.where((agent) {
      if (agent.name.toLowerCase().contains(query)) return true;
      final bio = agent.bio;
      if (bio != null && bio.toLowerCase().contains(query)) return true;
      final peerName = agent.sourcePeerName;
      if (peerName != null && peerName.toLowerCase().contains(query)) {
        return true;
      }
      return false;
    }).toList();
  }

  void _toggleAgent(RemoteAgent agent) {
    setState(() {
      if (_selectedIds.contains(agent.id)) {
        _selectedIds.remove(agent.id);
      } else {
        _selectedIds.add(agent.id);
      }
    });
  }

  void _confirm() {
    if (_selectedIds.isEmpty) return;
    Navigator.of(context).pop(_selectedAgents);
  }

  Widget _buildConfirmAction(AppLocalizations l10n) {
    return IconButton(
      onPressed: _selectedIds.isEmpty ? null : _confirm,
      icon: const Icon(Icons.check, size: 24),
      iconSize: 24,
      tooltip: l10n.common_confirm,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = _buildBody(l10n);

    if (!widget.wrappedInScaffold) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.chat_addMember),
        elevation: 1,
        actions: [
          _buildConfirmAction(l10n),
        ],
      ),
      body: body,
    );
  }

  Widget _buildFilterField(AppLocalizations l10n, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _filterController,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: l10n.common_search,
          hintStyle: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurfaceVariant,
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
          suffixIcon: _filterController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _filterController.clear(),
                )
              : null,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: colorScheme.primary.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (widget.availableAgents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.chat_noMoreAgents,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }

    final isDesktop = LayoutUtils.isDesktopLayout(context);
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filteredAgents;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.chat_addMember,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildConfirmAction(l10n),
              ],
            ),
          ),
        if (isDesktop) const Divider(height: 1),
        _buildFilterField(l10n, colorScheme),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.home_searchNoResults,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    ...filtered.map((agent) {
                      final selected = _selectedIds.contains(agent.id);
                      return CheckboxListTile(
                        value: selected,
                        onChanged: (_) => _toggleAgent(agent),
                        secondary: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            agent.name.isNotEmpty
                                ? agent.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: AppColors.primaryDark,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                agent.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (agent.isPeerAgent) ...[
                              const SizedBox(width: 6),
                              PeerSourceBadge.fromAgent(agent),
                            ],
                          ],
                        ),
                        subtitle: agent.bio != null && agent.bio!.isNotEmpty
                            ? Text(
                                agent.bio!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        controlAffinity: ListTileControlAffinity.trailing,
                      );
                    }),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
      ],
    );
  }
}
