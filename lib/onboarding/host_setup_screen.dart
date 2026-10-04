import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import 'host_entry.dart';
import 'host_entry_flow.dart';
import 'remote_host_guide.dart';

/// 桌面第一次进来：主机放在这台电脑，还是另一台。
class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({super.key});

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  bool _busy = false;
  bool _waitingForInstall = false;
  String _error = '';

  Future<void> _install() async {
    await HostModeStore.write(HostMode.thisComputer);
    await Clipboard.setData(ClipboardData(text: cliInstallCommand()));
    if (!mounted) return;
    setState(() {
      _waitingForInstall = true;
      _error = '';
    });
  }

  Future<void> _connectRemote() async {
    await HostModeStore.write(HostMode.remote);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RemoteHostGuideScreen()),
    );
  }

  Future<void> _redetect() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (!mounted) return;
      await HostEntryNavigator.go(
        context,
        isDesktop: Platform.isMacOS || Platform.isWindows || Platform.isLinux,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostSetup_title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.hostSetup_intro, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          _ChoiceCard(
            icon: Icons.computer,
            title: l10n.hostSetup_thisComputer,
            badge: l10n.hostSetup_recommended,
            body: l10n.hostSetup_thisComputerDesc,
            action: l10n.hostSetup_installAndStart,
            emphasized: true,
            onPressed: _busy ? null : _install,
          ),
          const SizedBox(height: 12),
          _ChoiceCard(
            icon: Icons.link,
            title: l10n.hostSetup_remote,
            body: l10n.hostSetup_remoteDesc,
            action: l10n.hostSetup_goConnect,
            emphasized: false,
            onPressed: _busy ? null : _connectRemote,
          ),
          if (_waitingForInstall) ...[
            const SizedBox(height: 16),
            Text(l10n.hostSetup_afterCopy),
          ],
          const SizedBox(height: 20),
          TextButton(
            onPressed: _busy ? null : _redetect,
            child: Text(l10n.hostSetup_redetect),
          ),
          if (_error.isNotEmpty)
            Text(_error, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : _connectRemote,
            child: Text(l10n.hostSetup_switchRemote),
          ),
        ],
      ),
    );
  }
}

String cliInstallCommand() {
  if (Platform.isWindows) {
    return 'irm https://release.shepaw.com/install.ps1 | iex';
  }
  return 'curl -fsSL https://release.shepaw.com/install.sh | sh';
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.emphasized,
    required this.onPressed,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String? badge;
  final String body;
  final String action;
  final bool emphasized;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: emphasized
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (badge != null)
                  Text(
                    badge!,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 12),
            emphasized
                ? FilledButton(onPressed: onPressed, child: Text(action))
                : OutlinedButton(onPressed: onPressed, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
