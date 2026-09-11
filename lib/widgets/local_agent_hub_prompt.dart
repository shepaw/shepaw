import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/local_agent_hub_models.dart';
import '../services/local_agent_hub_service.dart';
import '../services/logger_service.dart';
import '../theme/app_theme.dart';

const _nodejsUrl = 'https://nodejs.org';

bool _localHubPromptAttempted = false;
OverlayEntry? _nudgeEntry;

@visibleForTesting
void resetLocalHubPromptAttempted() {
  _localHubPromptAttempted = false;
  removeLocalAgentHubNudge();
}

/// Remove a leftover startup card (e.g. when the home screen disposes).
void removeLocalAgentHubNudge() {
  _nudgeEntry?.remove();
  _nudgeEntry = null;
}

/// Desktop-only: detect a local Agent Hub and offer to join or install it
/// without blocking the main window.
Future<void> maybePromptLocalAgentHub(BuildContext context) async {
  if (_localHubPromptAttempted) return;
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
  if (!context.mounted) return;
  _localHubPromptAttempted = true;

  final svc = LocalAgentHubService.instance;
  try {
    final detection = await svc.detect();
    if (!context.mounted) return;
    final suppressed = await svc.isPromptSuppressed(detection);
    final guideShown = await svc.addAgentGuideShown();
    if (!context.mounted) return;

    final decision = resolveLocalHubNudge(
      detection: detection,
      suppressed: suppressed,
      guideShown: guideShown,
    );

    switch (decision.kind) {
      case LocalHubNudgeKind.none:
        return;
      case LocalHubNudgeKind.emptyGuide:
        await svc.markAddAgentGuideShown();
        if (!context.mounted) return;
        _showConnectedSnack(context, empty: true);
        return;
      case LocalHubNudgeKind.join:
      case LocalHubNudgeKind.install:
        _insertNudge(
          context,
          svc: svc,
          detection: detection,
          install: decision.kind == LocalHubNudgeKind.install,
        );
    }
  } catch (e, st) {
    LoggerService().warning(
      'Local Agent Hub prompt failed: $e\n$st',
      tag: 'LocalAgentHub',
      error: e,
    );
  }
}

/// User-initiated join / install from Settings. Blocking progress is OK here.
Future<void> runLocalAgentHubAction(
  BuildContext context, {
  required bool install,
}) async {
  final svc = LocalAgentHubService.instance;
  await _runAction(
    context,
    svc,
    action: install
        ? (onProgress) => svc.installAndJoin(onProgress: onProgress)
        : (onProgress) => svc.join(onProgress: onProgress),
  );
}

Future<void> openLocalAgentHubDashboard() async {
  final uri = Uri.parse(kLocalAgentHubDashboardUrl);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

void _insertNudge(
  BuildContext context, {
  required LocalAgentHubService svc,
  required LocalHubDetection detection,
  required bool install,
}) {
  removeLocalAgentHubNudge();
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  final entry = OverlayEntry(
    builder: (_) {
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 20, 20),
            child: LocalHubNudgeCard(
              title: install
                  ? l10n.localHub_missingTitle
                  : l10n.localHub_nudgeJoinTitle,
              body: install
                  ? l10n.localHub_nudgeInstallBody
                  : l10n.localHub_nudgeJoinBody,
              actionLabel: install
                  ? l10n.localHub_installAndOpen
                  : l10n.localHub_join,
              dismissTooltip: l10n.localHub_dontAskAgain,
              onAction: () async {
                removeLocalAgentHubNudge();
                if (!context.mounted) return;
                await _runAction(
                  context,
                  svc,
                  action: install
                      ? (onProgress) =>
                          svc.installAndJoin(onProgress: onProgress)
                      : (onProgress) => svc.join(onProgress: onProgress),
                );
              },
              onDismiss: () async {
                await svc.dismissPrompt(fingerprint: detection.hubFingerprint);
                removeLocalAgentHubNudge();
              },
            ),
          ),
        ),
      );
    },
  );
  _nudgeEntry = entry;
  overlay.insert(entry);
}

Future<void> _runAction(
  BuildContext context,
  LocalAgentHubService svc, {
  required Future<LocalHubDetection> Function(
    void Function(LocalHubProgressStep step) onProgress,
  ) action,
}) async {
  final l10n = AppLocalizations.of(context);
  final step = ValueNotifier<LocalHubProgressStep>(
    LocalHubProgressStep.starting,
  );
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.localHub_workingTitle),
      content: AnimatedBuilder(
        animation: step,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Text(_stepLabel(l10n, step.value)),
          ],
        ),
      ),
    ),
  );

  try {
    final result = await action((s) => step.value = s);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    final empty = result.instanceCount == null || result.instanceCount == 0;
    await svc.markAddAgentGuideShown();
    if (!context.mounted) return;
    _showConnectedSnack(context, empty: empty);
  } on LocalHubException catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    await _showFailure(context, e);
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    await _showFailure(
      context,
      LocalHubException(e.toString(), code: 'unknown'),
    );
  } finally {
    step.dispose();
  }
}

String _stepLabel(AppLocalizations l10n, LocalHubProgressStep step) {
  switch (step) {
    case LocalHubProgressStep.checkingNode:
      return l10n.localHub_stepCheckingNode;
    case LocalHubProgressStep.installing:
      return l10n.localHub_stepInstalling;
    case LocalHubProgressStep.starting:
      return l10n.localHub_stepStarting;
    case LocalHubProgressStep.pairing:
      return l10n.localHub_stepPairing;
  }
}

void _showConnectedSnack(BuildContext context, {required bool empty}) {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        empty ? l10n.localHub_emptyGuideSnack : l10n.localHub_connectedSnack,
      ),
      action: SnackBarAction(
        label: l10n.localHub_openDashboard,
        onPressed: () {
          unawaited(openLocalAgentHubDashboard());
        },
      ),
    ),
  );
}

Future<void> _showFailure(BuildContext context, LocalHubException error) {
  final l10n = AppLocalizations.of(context);
  final nodeMissing = error.code == 'node-missing' || error.code == 'node-old';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        nodeMissing ? l10n.localHub_nodeMissingTitle : l10n.localHub_failedTitle,
      ),
      content: Text(
        nodeMissing
            ? l10n.localHub_nodeMissingBody
            : l10n.localHub_failedBody(error.message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.common_close),
        ),
        if (nodeMissing)
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final uri = Uri.parse(_nodejsUrl);
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: Text(l10n.localHub_installNode),
          )
        else
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await openLocalAgentHubDashboard();
            },
            child: Text(l10n.localHub_openDashboard),
          ),
      ],
    ),
  );
}

/// Non-blocking corner card. Close means “don't ask again”.
class LocalHubNudgeCard extends StatelessWidget {
  const LocalHubNudgeCard({
    super.key,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.dismissTooltip,
    required this.onAction,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final String actionLabel;
  final String dismissTooltip;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surface,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.hub_outlined, color: AppColors.primary, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: dismissTooltip,
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    onPressed: onAction,
                    child: Text(actionLabel),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desktop settings row: status plus join / install / open dashboard.
class LocalAgentHubSettingsTile extends StatefulWidget {
  const LocalAgentHubSettingsTile({super.key});

  @override
  State<LocalAgentHubSettingsTile> createState() =>
      _LocalAgentHubSettingsTileState();
}

class _LocalAgentHubSettingsTileState extends State<LocalAgentHubSettingsTile> {
  LocalHubDetection? _detection;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final detection = await LocalAgentHubService.instance.detect();
      if (!mounted) return;
      setState(() {
        _detection = detection;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _subtitle(AppLocalizations l10n) {
    final d = _detection;
    if (_loading || d == null) return l10n.settings_localHubSub;
    if (d.alreadyPaired) return l10n.settings_localHubConnected;
    if (d.isPresent) return l10n.settings_localHubInstalled;
    return l10n.settings_localHubMissing;
  }

  Future<void> _onTap() async {
    final d = _detection;
    if (d == null) return;
    if (d.alreadyPaired) {
      await openLocalAgentHubDashboard();
      return;
    }
    if (!mounted) return;
    await runLocalAgentHubAction(context, install: !d.isPresent);
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.hub_outlined),
      title: Text(l10n.settings_localHub),
      subtitle: Text(_subtitle(l10n)),
      trailing: _loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: _loading ? null : _onTap,
    );
  }
}
