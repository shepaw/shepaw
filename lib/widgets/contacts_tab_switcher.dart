import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 通讯录的两个分段：联系人（找人聊天）和设备（管基础设施）。
enum ContactsTab { people, devices }

/// 通讯录的分段切换。
///
/// 单独拆出来是为了能测：M3 的 [SegmentedButton] 激活底色默认取
/// `secondaryContainer`，本主题里那是 `accentContainer`（淡粉），和橘色主题
/// 不搭，所以显式换成 `primaryContainer`（浅色下淡橘，深色下自动换暗橘）。
class ContactsTabSwitcher extends StatelessWidget {
  const ContactsTabSwitcher({
    super.key,
    required this.tab,
    required this.onChanged,
  });

  final ContactsTab tab;
  final ValueChanged<ContactsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SegmentedButton<ContactsTab>(
        // 默认会在选中项前加一个对勾，两个文字标签的场景里多余。
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: colorScheme.primaryContainer,
          selectedForegroundColor: colorScheme.onPrimaryContainer,
          foregroundColor: colorScheme.onSurfaceVariant,
          side: BorderSide(color: colorScheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          visualDensity: VisualDensity.compact,
        ),
        segments: [
          ButtonSegment(
            value: ContactsTab.people,
            label: Text(l10n.contacts_tabPeople),
          ),
          ButtonSegment(
            value: ContactsTab.devices,
            label: Text(l10n.contacts_tabDevices),
          ),
        ],
        selected: {tab},
        onSelectionChanged: (next) => onChanged(next.first),
      ),
    );
  }
}
