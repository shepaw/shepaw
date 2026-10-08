import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../utils/engine_avatars.dart';
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
                color: engine.available
                    ? EngineStatusChip.availableColor(context)
                    : null,
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
    final asset = defaultAvatarForEngine(engine.id);
    final child = asset == kGenericDefaultAvatar
        ? _fallback()
        : SvgPicture.asset(
            asset,
            width: size - 8,
            height: size - 8,
            placeholderBuilder: (_) => _fallback(),
          );
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
    this.color,
  });

  final String label;
  final bool positive;

  /// 指定后覆盖正/负态的默认色。「可用」传入 [availableColor]。
  final Color? color;

  /// 「可用」标签的绿色。深色模式用更亮的绿，保证在深色底上还能看清。
  static Color availableColor(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = color ?? (positive ? scheme.primary : scheme.error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: resolved, fontSize: 11)),
    );
  }
}

/// 添加 Agent 实例时用来选引擎。可用项写入选择，不可用项打开配置，不改当前值。
class AgentEngineDropdown extends StatelessWidget {
  const AgentEngineDropdown({
    super.key,
    required this.engines,
    required this.selectedId,
    required this.enabled,
    required this.onSelected,
    required this.onUnavailable,
  });

  final List<PeerEngineEntry> engines;
  final String? selectedId;
  final bool enabled;
  final ValueChanged<PeerEngineEntry> onSelected;
  final ValueChanged<PeerEngineEntry> onUnavailable;

  @override
  Widget build(BuildContext context) {
    if (engines.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final selected =
        engines.any((engine) => engine.id == selectedId) ? selectedId : null;
    return InputDecorator(
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selected,
          isExpanded: true,
          itemHeight: null,
          menuMaxHeight: 360,
          hint: Text(l10n.addAgent_engine),
          borderRadius: BorderRadius.circular(8),
          selectedItemBuilder: (context) => [
            for (final engine in engines) _label(context, engine),
          ],
          items: [
            for (final engine in engines)
              DropdownMenuItem<String>(
                value: engine.id,
                child: _menuEntry(context, engine),
              ),
          ],
          onChanged: enabled ? (id) => _onChanged(id) : null,
        ),
      ),
    );
  }

  void _onChanged(String? id) {
    if (id == null) return;
    final engine = engines.where((item) => item.id == id).firstOrNull;
    if (engine == null) return;
    if (!engine.available) {
      onUnavailable(engine);
      return;
    }
    onSelected(engine);
  }

  Widget _label(BuildContext context, PeerEngineEntry engine) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        children: [
          EngineAvatar(engine: engine, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              engine.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _availabilityChip(context, engine),
        ],
      ),
    );
  }

  Widget _menuEntry(BuildContext context, PeerEngineEntry engine) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            EngineAvatar(engine: engine, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                engine.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _availabilityChip(context, engine),
            if (!engine.available) ...[
              const SizedBox(width: 8),
              Text(
                l10n.addAgent_configure,
                style: TextStyle(color: scheme.primary, fontSize: 13),
              ),
            ],
          ],
        ),
        if (!engine.available && engine.unavailableReason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 2),
            child: Text(
              engine.unavailableReason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _availabilityChip(BuildContext context, PeerEngineEntry engine) {
    final l10n = AppLocalizations.of(context);
    return EngineStatusChip(
      label: engine.available
          ? l10n.addAgent_available
          : l10n.addAgent_unavailable,
      positive: engine.available,
      color:
          engine.available ? EngineStatusChip.availableColor(context) : null,
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
