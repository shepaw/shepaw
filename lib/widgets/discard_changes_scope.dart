import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Asks whether to discard unsaved edits. Returns true when the user confirms.
Future<bool> confirmDiscardChanges(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showConfirmDialog(
    context,
    message: l10n.common_discardUnsaved,
  );
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  String? title,
  required String message,
  String? confirmLabel,
  bool destructive = true,
}) async {
  final l10n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: title == null ? null : Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            confirmLabel ?? l10n.common_confirm,
            style: TextStyle(
              color: destructive ? Theme.of(dialogContext).colorScheme.error : null,
            ),
          ),
        ),
      ],
    ),
  );
  return result == true;
}

/// Blocks system back while [dirty] is true and asks before leaving.
///
/// Call [DiscardChangesScopeState.allowPop] before an intentional
/// [Navigator.pop] that should skip the prompt (for example after a
/// successful save). The scope must be built under the calling [State];
/// hold a [GlobalKey] to reach it.
class DiscardChangesScope extends StatefulWidget {
  const DiscardChangesScope({
    super.key,
    required this.dirty,
    required this.child,
  });

  final bool dirty;
  final Widget child;

  @override
  State<DiscardChangesScope> createState() => DiscardChangesScopeState();
}

class DiscardChangesScopeState extends State<DiscardChangesScope> {
  bool _bypass = false;

  /// Lets the next pop through without asking. Waits one frame so [canPop]
  /// has been rebuilt.
  Future<void> allowPop() {
    if (_bypass) return Future.value();
    final done = Completer<void>();
    setState(() => _bypass = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  Future<void> _leave() async {
    if (!mounted) return;
    if (widget.dirty) {
      final discard = await confirmDiscardChanges(context);
      if (!discard || !mounted) return;
    }
    await allowPop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _bypass || !widget.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: widget.child,
    );
  }
}
