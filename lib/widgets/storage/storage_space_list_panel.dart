import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/storage_shared.dart';
import '../../storage/device_identity.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';
import '../../theme/app_theme.dart';

/// 桌面储物袋左侧面板：最近 + 「我的」/「智能体」分区列表。
///
/// 选中回调由父级在右侧 master-detail 展示对应内容：
/// 「最近」→ 最近文件列表；分区 → 该分区文件浏览。
class StorageSpaceListPanel extends StatefulWidget {
  /// 是否高亮「最近」。
  final bool recentSelected;

  /// 当前选中的分区（null = 最近）。
  final String? selectedSpace;

  final VoidCallback? onRecentSelected;
  final ValueChanged<String>? onSpaceSelected;

  /// 追加在列表底部的入口。
  final List<Widget> footer;

  const StorageSpaceListPanel({
    super.key,
    this.recentSelected = false,
    this.selectedSpace,
    this.onRecentSelected,
    this.onSpaceSelected,
    this.footer = const [],
  });

  @override
  State<StorageSpaceListPanel> createState() => StorageSpaceListPanelState();
}

class StorageSpaceListPanelState extends State<StorageSpaceListPanel> {
  static const double _avatarSize = 36;

  String _selfId = '';
  bool _loading = true;
  Map<String, int> _spaceBytes = const {};
  StreamSubscription<void>? _usageSub;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void dispose() {
    _usageSub?.cancel();
    super.dispose();
  }

  Future<void> reload() async {
    try {
      final self = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      final stats = await store.stats(blocking: false);
      final bytes = storageDeviceSpaceBytes(stats, self);
      unawaited(_subscribeUsage());
      if (!mounted) return;
      setState(() {
        _selfId = self;
        _spaceBytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _subscribeUsage() async {
    try {
      final store = await StoreService.instance.localStore();
      _usageSub?.cancel();
      _usageSub = store.usageUpdates.listen((_) async {
        if (!mounted || _selfId.isEmpty) return;
        final stats = await store.stats(blocking: false);
        final bytes = storageDeviceSpaceBytes(stats, _selfId);
        if (mounted) setState(() => _spaceBytes = bytes);
      });
    } catch (_) {}
  }

  IconData _spaceIcon(String space) {
    switch (space) {
      case StoreSpace.workspaces:
        return Icons.work_outline;
      case StoreSpace.runtime:
        return Icons.bolt_outlined;
      case StoreSpace.files:
        return Icons.folder_outlined;
      case StoreSpace.slips:
        return Icons.auto_stories_outlined;
      case StoreSpace.instructions:
        return Icons.playlist_add_check_outlined;
      case StoreSpace.public_:
        return Icons.public;
      case StoreSpace.cognition:
        return Icons.psychology_outlined;
      case StoreSpace.artifacts:
        return Icons.extension_outlined;
      case StoreSpace.tools:
        return Icons.build_outlined;
      default:
        return Icons.folder_outlined;
    }
  }

  Widget _leadingIconBox(IconData icon) {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 20, color: AppColors.primary),
    );
  }

  Widget _hubRow({
    required Widget leading,
    required String title,
    String? subtitle,
    bool selected = false,
    Widget trailing = const Icon(Icons.chevron_right, size: 20),
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              leading,
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
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(AppLocalizations l10n, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey[600],
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildRecentRow(AppLocalizations l10n) {
    return _hubRow(
      leading: _leadingIconBox(Icons.history),
      title: l10n.storage_spaceRecent,
      selected: widget.recentSelected,
      onTap: widget.onRecentSelected,
    );
  }

  Widget _buildNotesRow(AppLocalizations l10n) {
    return _hubRow(
      leading: _leadingIconBox(Icons.auto_stories_outlined),
      title: l10n.jadeSlip_title,
      subtitle: l10n.jadeSlip_entryHint,
      selected: widget.selectedSpace == StoreSpace.slips,
      onTap: () => widget.onSpaceSelected?.call(StoreSpace.slips),
    );
  }

  Widget _buildInstructionsRow(AppLocalizations l10n) {
    return _hubRow(
      leading: _leadingIconBox(Icons.playlist_add_check_outlined),
      title: l10n.instructionSet_title,
      subtitle: l10n.instructionSet_subtitle,
      selected: widget.selectedSpace == StoreSpace.instructions,
      onTap: () => widget.onSpaceSelected?.call(StoreSpace.instructions),
    );
  }

  Widget _buildSpaceRow(AppLocalizations l10n, String space) {
    final bytes = _spaceBytes[space];
    final subtitle = space == StoreSpace.tools
        ? l10n.storage_spaceToolsHint
        : (bytes == null ? null : fmtStorageBytes(bytes));
    return _hubRow(
      leading: _leadingIconBox(_spaceIcon(space)),
      title: storageSpaceLabel(l10n, space),
      subtitle: subtitle,
      selected: widget.selectedSpace == space,
      onTap: () => widget.onSpaceSelected?.call(space),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final userSpaces =
        StoreSpace.userVisibleSpaces(StoreSpace.browserSpaces);
    final agentSpaces =
        StoreSpace.agentVisibleSpaces(StoreSpace.browserSpaces);

    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildRecentRow(l10n),
          const Divider(height: 16, indent: 64),
          _buildSectionHeader(l10n, l10n.storage_categoryMine),
          _buildNotesRow(l10n),
          _buildInstructionsRow(l10n),
          if (userSpaces.isNotEmpty) ...[
            for (final space in userSpaces) _buildSpaceRow(l10n, space),
          ],
          if (agentSpaces.isNotEmpty) ...[
            const Divider(height: 16, indent: 64),
            _buildSectionHeader(l10n, l10n.storage_categoryAgents),
            for (final space in agentSpaces) _buildSpaceRow(l10n, space),
          ],
          ...widget.footer,
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        elevation: 0,
      ),
      body: _buildBody(l10n),
    );
  }
}
