import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';

/// 桌面的全局快捷键。
///
/// ⌘/Ctrl + 1..5 切模块，⌘, 设置，⌘K 搜索，⌘N 新会话。
/// 用 [Shortcuts] + [Actions] 包在 [child] 外面：输入框聚焦时这些组合键
/// 仍然先走到这里，不会被 TextField 吃掉。
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.onSelectModule,
    required this.onOpenSettings,
    required this.onFocusSearch,
    required this.onNewSession,
    required this.onNewJadeSlip,
    required this.onNewInstruction,
    required this.onOpenLog,
    required this.child,
  });

  /// 0..4 对应 聊天 / 通讯录 / 工作流 / 玉简 / 文件。
  final ValueChanged<int> onSelectModule;
  final VoidCallback onOpenSettings;
  final VoidCallback onFocusSearch;
  final VoidCallback onNewSession;
  final VoidCallback onNewJadeSlip;
  final VoidCallback onNewInstruction;

  /// 打开浮窗日志，参数见 [LayoutUtils.openFloatingPanel] 的 key。
  final void Function(String key) onOpenLog;

  final Widget child;

  static const _openSettings = _OpenSettingsIntent._();
  static const _focusSearch = _FocusSearchIntent._();
  static const _newSession = _NewSessionIntent._();

  static LogicalKeySet _mod(LogicalKeyboardKey key) =>
      LogicalKeySet(isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control, key);

  static bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        _mod(LogicalKeyboardKey.digit1):
            const _SwitchModuleIntent._(index: 0),
        _mod(LogicalKeyboardKey.digit2):
            const _SwitchModuleIntent._(index: 1),
        _mod(LogicalKeyboardKey.digit3):
            const _SwitchModuleIntent._(index: 2),
        _mod(LogicalKeyboardKey.digit4):
            const _SwitchModuleIntent._(index: 3),
        _mod(LogicalKeyboardKey.digit5):
            const _SwitchModuleIntent._(index: 4),
        _mod(LogicalKeyboardKey.comma): _openSettings,
        _mod(LogicalKeyboardKey.keyK): _focusSearch,
        _mod(LogicalKeyboardKey.keyN): _newSession,
      },
      child: Actions(
        actions: {
          _SwitchModuleIntent: CallbackAction<_SwitchModuleIntent>(
            onInvoke: (intent) => onSelectModule(intent.index),
          ),
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) => onOpenSettings(),
          ),
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) => onFocusSearch(),
          ),
          _NewSessionIntent: CallbackAction<_NewSessionIntent>(
            onInvoke: (_) => onNewSession(),
          ),
        },
        child: child,
      ),
    );
  }

  /// macOS 顶部菜单栏。别的桌面平台不显示。
  static Widget menuBar({
    required BuildContext context,
    required Widget child,
    required VoidCallback onAbout,
    required VoidCallback onOpenSettings,
    required VoidCallback onNewSession,
    required VoidCallback onNewJadeSlip,
    required VoidCallback onNewInstruction,
    required void Function(String key) onOpenLog,
  }) {
    if (!isMacOS) return child;
    final l10n = AppLocalizations.of(context);
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: l10n.appTitle,
          menus: [
            PlatformMenuItem(
              label: l10n.settings_about,
              onSelected: onAbout,
            ),
            PlatformMenuItem(
              label: l10n.nav_settings,
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              onSelected: onOpenSettings,
            ),
          ],
        ),
        PlatformMenu(
          label: l10n.menu_file,
          menus: [
            PlatformMenuItem(
              label: l10n.chat_newSession,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
              onSelected: onNewSession,
            ),
            PlatformMenuItem(
              label: l10n.jadeSlip_create,
              onSelected: onNewJadeSlip,
            ),
            PlatformMenuItem(
              label: l10n.instructionSet_create,
              onSelected: onNewInstruction,
            ),
          ],
        ),
        PlatformMenu(
          label: l10n.menu_window,
          menus: [
            PlatformMenuItem(
              label: l10n.settings_inferenceLog,
              onSelected: () => onOpenLog('inference_log'),
            ),
            PlatformMenuItem(
              label: l10n.settings_systemLog,
              onSelected: () => onOpenLog('system_log'),
            ),
          ],
        ),
      ],
      child: child,
    );
  }
}

class _SwitchModuleIntent extends Intent {
  const _SwitchModuleIntent._({this.index = 0});

  final int index;
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent._();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent._();
}

class _NewSessionIntent extends Intent {
  const _NewSessionIntent._();
}
