import 'package:flutter/material.dart';
import 'dart:io' show Platform;

import '../../l10n/app_localizations.dart';

/// 「我的」中栏里的页面。桌面只比手机多一项定时任务。
enum MinePage {
  profile,
  models,
  instructions,
  skills,
  cli,
  events,
  scheduledTasks,
}

/// 桌面「我的」模式的中栏：名片 + 能力列表。选中后在右栏打开对应页。
class MineListPanel extends StatelessWidget {
  const MineListPanel({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final MinePage? selected;
  final ValueChanged<MinePage> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final entries = [
      (MinePage.profile, Icons.person_outline, l10n.settings_userProfile),
      (MinePage.models, Icons.memory_outlined, l10n.toolModel_managementTitle),
      (MinePage.instructions, Icons.playlist_add_check_outlined,
          l10n.instructionSet_title),
      (MinePage.skills, Icons.auto_awesome_outlined, l10n.skillMgmt_title),
      (MinePage.cli, Icons.terminal, l10n.osTool_configTitle),
      (MinePage.events, Icons.sensors, l10n.eventMgmt_title),
      if (!(Platform.isAndroid || Platform.isIOS))
        (MinePage.scheduledTasks, Icons.schedule, l10n.scheduledTasks_title),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.nav_mine), automaticallyImplyLeading: false),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              l10n.mine_sectionCapabilities,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ),
          for (final entry in entries)
            _Row(
              icon: entry.$2,
              label: entry.$3,
              selected: selected == entry.$1,
              highlight: scheme.primary,
              onTap: () => onSelected(entry.$1),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.selected,
    required this.highlight,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? highlight.withValues(alpha: 0.10) : Colors.transparent,
      child: ListTile(
        leading: Icon(icon, color: selected ? highlight : null),
        title: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? highlight : scheme.onSurface,
          ),
        ),
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}
