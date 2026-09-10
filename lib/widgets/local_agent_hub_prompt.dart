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

/// Desktop-only: detect a local Agent Hub and offer to join or install it.
Future<void> maybePromptLocalAgentHub(BuildContext context) async {
  if (_localHubPromptAttempted) return;
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
  if (!context.mounted) return;
  _localHubPromptAttempted = true;

  final svc = LocalAgentHubService.instance;
  try {
    if (await svc.isSnoozed()) return;
    final detection = await svc.detect();
    if (!context.mounted) return;

    if (detection.alreadyPaired) {
      final empty = detection.instanceCount == 0;
      if (empty &&
          detection.presence == LocalHubPresence.running &&
          !await svc.addAgentGuideShown()) {
        if (!context.mounted) return;
        await _showJoinedGuide(context, svc, empty: true);
      }
      return;
    }

    if (detection.isPresent) {
      final join = await _showJoinPrompt(context);
      if (!context.mounted) return;
      if (join != true) {
        await svc.snooze();
        return;
      }
      await _runAction(
        context,
        svc,
        action: (onProgress) => svc.join(onProgress: onProgress),
      );
      return;
    }

    final install = await _showInstallPrompt(context);
    if (!context.mounted) return;
    if (install != true) {
      await svc.snooze();
      return;
    }
    await _runAction(
      context,
      svc,
      action: (onProgress) => svc.installAndJoin(onProgress: onProgress),
    );
  } catch (e, st) {
    LoggerService().warning(
      'Local Agent Hub prompt failed: $e\n$st',
      tag: 'LocalAgentHub',
      error: e,
    );
  }
}

Future<bool?> _showJoinPrompt(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.hub_outlined, size: 40, color: AppColors.primary),
      title: Text(l10n.localHub_detectedTitle),
      content: Text(l10n.localHub_detectedBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.localHub_later),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.localHub_join),
        ),
      ],
    ),
  );
}

Future<bool?> _showInstallPrompt(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.download_outlined, size: 40, color: AppColors.primary),
      title: Text(l10n.localHub_missingTitle),
      content: Text(l10n.localHub_missingBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.localHub_later),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.localHub_installAndOpen),
        ),
      ],
    ),
  );
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
    await _showJoinedGuide(context, svc, empty: empty);
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

Future<void> _showJoinedGuide(
  BuildContext context,
  LocalAgentHubService svc, {
  required bool empty,
}) async {
  final l10n = AppLocalizations.of(context);
  await svc.markAddAgentGuideShown();
  if (!context.mounted) return;
  if (empty) unawaited(_openDashboard());
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.check_circle_outline, size: 40, color: AppColors.primary),
      title: Text(l10n.localHub_joinedTitle),
      content: Text(
        empty ? l10n.localHub_joinedEmptyBody : l10n.localHub_joinedBody,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.common_ok),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await _openDashboard();
          },
          child: Text(l10n.localHub_openDashboard),
        ),
      ],
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
        nodeMissing ? l10n.localHub_nodeMissingBody : l10n.localHub_failedBody(error.message),
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
              await _openDashboard();
            },
            child: Text(l10n.localHub_openDashboard),
          ),
      ],
    ),
  );
}

Future<void> _openDashboard() async {
  final uri = Uri.parse(kLocalAgentHubDashboardUrl);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
