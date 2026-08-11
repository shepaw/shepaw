import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/layout_utils.dart';

/// Agent Soul editor (persona / identity text).
///
/// Pair with [LayoutUtils.showRightDrawer] on desktop or a full-screen
/// [Scaffold] route on mobile — same presentation as [SessionListPanel].
class SoulPanel extends StatefulWidget {
  final String initialSoul;
  final Future<bool> Function(String soul) onSave;
  final bool readOnly;

  const SoulPanel({
    super.key,
    required this.initialSoul,
    required this.onSave,
    this.readOnly = false,
  });

  @override
  State<SoulPanel> createState() => _SoulPanelState();
}

class _SoulPanelState extends State<SoulPanel> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialSoul);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_saving || widget.readOnly) return;
    setState(() => _saving = true);
    try {
      final shouldClose = await widget.onSave(_controller.text);
      if (mounted && shouldClose) Navigator.of(context).pop();
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
              readOnly: widget.readOnly,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              autofocus: !widget.readOnly,
              decoration: InputDecoration(
                hintText: l10n.chat_soulHint,
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
              if (!widget.readOnly)
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
                child: Text(widget.readOnly ? l10n.common_close : l10n.common_cancel),
              ),
              if (!widget.readOnly) ...[
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
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(AppLocalizations l10n, bool isDesktop) {
    if (!isDesktop) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.chat_soulTitle,
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

/// @deprecated Use [SoulPanel] instead.
typedef SystemPromptPanel = SoulPanel;
