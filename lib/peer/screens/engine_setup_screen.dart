import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../services/peer_agent_client_service.dart';

/// 引擎不可用时的配置说明。文档链接和启动命令来自主机，版式对齐 agent-bridge 的引擎设置。
class EngineSetupScreen extends StatelessWidget {
  const EngineSetupScreen({
    super.key,
    required this.engine,
    required this.hostOnline,
  });

  final PeerEngineEntry engine;
  final bool hostOnline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final command =
        engine.acpCommand.isNotEmpty ? engine.acpCommand : engine.command;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addAgent_setupTitle(engine.name))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              EngineAvatar(engine: engine, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  engine.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              EngineStatusChip(
                label:
                    hostOnline ? l10n.addAgent_online : l10n.addAgent_offline,
                positive: hostOnline,
              ),
              EngineStatusChip(
                label: engine.available
                    ? l10n.addAgent_available
                    : l10n.addAgent_unavailable,
                positive: engine.available,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(l10n.addAgent_setupIntro),
          if (engine.unavailableReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              engine.unavailableReason,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (command.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(l10n.addAgent_setupCommand,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _CommandBlock(command: command),
          ],
          const SizedBox(height: 20),
          if (engine.docsUrl.isNotEmpty)
            FilledButton.icon(
              onPressed: () => _openDocs(engine.docsUrl),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(l10n.addAgent_openDocs),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.addAgent_redetect),
          ),
        ],
      ),
    );
  }

  Future<void> _openDocs(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class EngineAvatar extends StatelessWidget {
  const EngineAvatar({super.key, required this.engine, this.size = 32});

  final PeerEngineEntry engine;
  final double size;

  @override
  Widget build(BuildContext context) {
    final plate = AppColors.avatarPlateFor(Theme.of(context).brightness);
    Widget child;
    final data = engine.avatarData;
    if (data.isNotEmpty && engine.avatarExt == 'svg') {
      try {
        child = SvgPicture.memory(
          base64Decode(data),
          width: size - 8,
          height: size - 8,
        );
      } catch (_) {
        child = _fallback();
      }
    } else {
      child = _fallback();
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: plate,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  Widget _fallback() {
    final letter = engine.name.isNotEmpty ? engine.name[0] : '?';
    return Text(letter, style: const TextStyle(fontWeight: FontWeight.w700));
  }
}

class EngineStatusChip extends StatelessWidget {
  const EngineStatusChip({
    super.key,
    required this.label,
    required this.positive,
  });

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = positive ? scheme.primary : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Clipboard.setData(ClipboardData(text: command)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(command, style: const TextStyle(fontFamily: 'monospace')),
        ),
      ),
    );
  }
}
