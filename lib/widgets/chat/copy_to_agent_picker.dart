import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../peer/widgets/peer_source_badge.dart';
import '../../utils/layout_utils.dart';
import '../agent_list_avatar.dart';

/// Single-select agent picker for the session row menu's「复制到」action.
///
/// Picking an agent pops it back to the caller. On mobile the content is
/// wrapped in a [Scaffold] with the title in the app bar; on desktop it is
/// rendered as-is (the right drawer host provides the frame).
class CopyToAgentPicker extends StatefulWidget {
  final List<RemoteAgent> availableAgents;
  final bool wrappedInScaffold;

  const CopyToAgentPicker({
    super.key,
    required this.availableAgents,
    this.wrappedInScaffold = false,
  });

  @override
  State<CopyToAgentPicker> createState() => _CopyToAgentPickerState();
}

class _CopyToAgentPickerState extends State<CopyToAgentPicker> {
  final TextEditingController _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = _buildBody(l10n);

    if (!widget.wrappedInScaffold) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.chat_copySessionToTitle),
        elevation: 1,
      ),
      body: body,
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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.chat_copySessionToTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                    ...filtered.map((agent) => ListTile(
                          leading: AgentListAvatar(
                            avatar: agent.avatar,
                            name: agent.name,
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
                          onTap: () => Navigator.of(context).pop(agent),
                        )),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
      ],
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
}
