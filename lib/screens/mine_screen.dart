import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/services/hub_she_mind.dart';
import '../service_locator.dart';
import '../services/update_service.dart';
import '../storage/store_protocol.dart';
import '../widgets/update_settings_badge.dart';
import 'settings/settings_sections.dart';
import 'settings_screen.dart';
import 'user_profile_settings_screen.dart';
import 'storage_shared.dart';
import 'storage_space_manage_screen.dart';

/// 手机底栏「我的」页。
///
/// 分四层：我是谁（名片）、我有什么（文件）、我能用什么（能力）、应用怎么配
/// （设置）。个人档案和能力项原来散在设置里，它们不是偏好设置，归到这里更
/// 顺手；桌面端的中栏复用同一套分区（[SettingsSections.capabilities]）。
class MineScreen extends StatelessWidget {
  const MineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.nav_mine),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          _ProfileCard(l10n: l10n),
          const Divider(height: 24),
          _SectionHeader(l10n.mine_sectionContent),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(storageSpaceLabel(l10n, StoreSpace.files)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(
              context,
              const StorageSpaceManageScreen(initialSpace: StoreSpace.files),
            ),
          ),
          const Divider(height: 24),
          _SectionHeader(l10n.mine_sectionCapabilities),
          ...SettingsSections.capabilities(
            context,
            l10n: l10n,
            openPage: (page) => _open(context, page),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const SettingsUpdateBadge(
              child: Icon(Icons.settings_outlined),
            ),
            title: Text(l10n.nav_settings),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              UpdateService().dismissSettingsIconBadge();
              _open(context, const SettingsScreen());
            },
          ),
          SizedBox(height: 8, child: ColoredBox(color: scheme.surface)),
        ],
      ),
    );
  }

  static Future<void> _open(BuildContext context, Widget page) {
    return Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

/// 顶部名片：头像（首字母占位）+ 昵称 + 一行摘要，点开是个人档案。
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Map<String, String>>(
      // 档案在主机上（惜宝的 mind），拿不到就退回空档案，不挡住整页。
      future: _loadProfile(),
      builder: (context, snapshot) {
        final profile = snapshot.data ?? const <String, String>{};
        final name = _pick(profile, 'name')?.trim() ?? '';
        final summary = _summary(profile);
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: CircleAvatar(
            radius: 28,
            backgroundColor: scheme.primary.withValues(alpha: 0.12),
            child: Text(
              name.isNotEmpty ? name.characters.first : '我',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          title: Text(
            name.isNotEmpty ? name : l10n.mine_profileUnnamed,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          subtitle: summary == null ? null : Text(summary),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => MineScreen._open(
            context,
            const UserProfileSettingsScreen(),
          ),
        );
      },
    );
  }

  Future<Map<String, String>> _loadProfile() async {
    try {
      return await getIt<HubSheMind>().profile();
    } catch (_) {
      return const {};
    }
  }

  static String? _pick(Map<String, String> profile, String key) =>
      profile[key];

  /// 一行摘要：有职业 / 城市就拼起来，都没有就不显示副标题。
  String? _summary(Map<String, String> profile) {
    final parts = [
      for (final key in ['occupation', 'city'])
        (_pick(profile, key) ?? '').trim(),
    ].where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }
}
