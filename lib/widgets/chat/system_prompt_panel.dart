import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/layout_utils.dart';

/// Session-level custom system prompt editor.
///
/// Pair with [LayoutUtils.showRightDrawer] on desktop or a full-screen
/// [Scaffold] route on mobile — same presentation as [SessionListPanel].
class SystemPromptPanel extends StatefulWidget {
  final String initialPrompt;
  final Future<void> Function(String prompt) onSave;

  const SystemPromptPanel({
    super.key,
    required this.initialPrompt,
    required this.onSave,
  });

  @override
  State<SystemPromptPanel> createState() => _SystemPromptPanelState();
}

class _SystemPromptPanelState extends State<SystemPromptPanel> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPrompt);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(l10n, isDesktop),
        if (isDesktop) const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.chat_systemPromptHint,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        _controller.clear();
                        setState(() {});
                      },
                child: Text(l10n.common_clear),
              ),
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.common_cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _handleSave,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.common_save),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(AppLocalizations l10n, bool isDesktop) {
    // Mobile uses Scaffold AppBar for title/back; desktop drawer needs its own.
    if (!isDesktop) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.chat_systemPromptTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
