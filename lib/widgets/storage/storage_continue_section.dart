import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/instruction_set.dart';
import '../../models/jade_slip.dart';
import '../../screens/instruction_set_editor_screen.dart';
import '../../screens/jade_slip_editor_screen.dart';
import '../../screens/storage_shared.dart';
import '../../services/instruction_set_service.dart';
import '../../services/jade_slip_service.dart';
import '../../services/store_open_service.dart';
import '../../storage/device_identity.dart';
import '../../storage/storage_continue.dart';
import '../../storage/store_file_visual.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';

/// 空间列表顶部的短列表：最近几条还会再打开的文件。
class StorageContinueSection extends StatefulWidget {
  const StorageContinueSection({
    super.key,
    this.includeDedicatedRecords = true,
    this.onItemTap,
    this.isSelected,
  });

  /// 附件选择时跳过玉简 / 指令集正文，它们不能当普通文件附上。
  final bool includeDedicatedRecords;

  /// 非 null 时由调用方处理点击（预览或勾选）。
  final Future<void> Function(StorageContinueItem item)? onItemTap;

  final bool Function(StorageContinueItem item)? isSelected;

  @override
  State<StorageContinueSection> createState() => StorageContinueSectionState();
}

class StorageContinueSectionState extends State<StorageContinueSection> {
  List<StorageContinueItem> _items = const [];
  StreamSubscription<void>? _usageSub;
  StreamSubscription<void>? _jadeSub;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
    unawaited(_listen());
  }

  @override
  void didUpdateWidget(StorageContinueSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.includeDedicatedRecords != widget.includeDedicatedRecords) {
      unawaited(reload());
    }
  }

  @override
  void dispose() {
    _usageSub?.cancel();
    _jadeSub?.cancel();
    super.dispose();
  }

  Future<void> reload() async {
    try {
      final items = await loadStorageContinueItems(
        includeDedicatedRecords: widget.includeDedicatedRecords,
      );
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  Future<void> _listen() async {
    _jadeSub = JadeSlipService.instance.changes.listen((_) {
      if (mounted) unawaited(reload());
    });
    try {
      final store = await StoreService.instance.localStore();
      _usageSub = store.usageUpdates.listen((_) {
        if (mounted) unawaited(reload());
      });
    } catch (_) {}
  }

  Future<void> _onTap(StorageContinueItem item) async {
    final custom = widget.onItemTap;
    if (custom != null) {
      await custom(item);
    } else if (mounted) {
      await openStorageContinueItem(context, item);
    }
    if (mounted) unawaited(reload());
  }

  String _title(AppLocalizations l10n, StorageContinueItem item) {
    final title = item.displayTitle?.trim();
    if (title != null && title.isNotEmpty) return title;
    if (item.space == StoreSpace.slips && JadeSlip.isRecordPath(item.path)) {
      return l10n.jadeSlip_title;
    }
    if (item.space == StoreSpace.instructions &&
        InstructionSet.isRecordPath(item.path)) {
      return l10n.instructionSet_title;
    }
    return StoreFileVisual.displayFriendlyName(l10n, item.space, item.path);
  }

  String _subtitle(AppLocalizations l10n, StorageContinueItem item) {
    final parts = <String>[storageSpaceLabel(l10n, item.space)];
    if (item.mtimeMs > 0) {
      final t = DateTime.fromMillisecondsSinceEpoch(item.mtimeMs).toLocal();
      final time =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      final locale = Localizations.localeOf(context);
      final date = locale.languageCode == 'zh'
          ? '${t.month}月${t.day}日'
          : '${t.month}/${t.day}';
      parts.add('$date $time');
    }
    return parts.join(' · ');
  }

  IconData _icon(StorageContinueItem item) {
    if (item.space == StoreSpace.slips && JadeSlip.isRecordPath(item.path)) {
      return Icons.auto_stories_outlined;
    }
    if (item.space == StoreSpace.instructions &&
        InstructionSet.isRecordPath(item.path)) {
      return Icons.playlist_add_check_outlined;
    }
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(
            l10n.storage_continueTitle,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
        for (final item in _items)
          _ContinueRow(
            icon: _icon(item),
            title: _title(l10n, item),
            subtitle: _subtitle(l10n, item),
            selected: widget.isSelected?.call(item) ?? false,
            onTap: () => unawaited(_onTap(item)),
          ),
        const Divider(height: 16, indent: 64),
      ],
    );
  }
}

class _ContinueRow extends StatelessWidget {
  const _ContinueRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 直接打开一条「接着打开」：玉简和指令集进各自编辑页，其余走文件预览。
Future<void> openStorageContinueItem(
  BuildContext context,
  StorageContinueItem item,
) async {
  if (item.space == StoreSpace.slips && JadeSlip.isRecordPath(item.path)) {
    final id = JadeSlip.idFromRecordPath(item.path);
    if (id == null || id.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JadeSlipEditorScreen(slipId: id),
      ),
    );
    return;
  }
  if (item.space == StoreSpace.instructions &&
      InstructionSet.isRecordPath(item.path)) {
    final id = InstructionSet.idFromRecordPath(item.path);
    if (id == null || id.isEmpty) return;
    final record = await InstructionSetService.instance.getById(id);
    if (record == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InstructionSetEditorScreen(item: record),
      ),
    );
    return;
  }
  final deviceId = await DeviceIdentity.deviceId();
  if (!context.mounted) return;
  await StoreOpenService.instance.openStoreUri(
    context,
    storeUriWithRef(item.space, deviceId, item.path),
  );
}
