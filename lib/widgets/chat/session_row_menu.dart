import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../services/error_handler_service.dart';
import '../../utils/session_utils.dart';

/// 会话行操作：移动端长按出底部菜单，桌面端点「更多」出下拉菜单。
///
/// - 查看会话（仅非当前会话）
/// - 查看 Trace
/// - 分叉（复制当前会话到新会话）
/// - 复制到（复制当前会话到另一个 agent 的新会话）
/// - 重置会话（仅当前会话且回调非空）
/// - 复制会话信息（标题、会话 ID、channel ID）
class _SessionRowAction {
  const _SessionRowAction({
    required this.value,
    required this.icon,
    required this.label,
  });

  final String value;
  final IconData icon;
  final String label;
}

List<_SessionRowAction> _sessionRowActions({
  required AppLocalizations l10n,
  required bool isCurrentSession,
  required VoidCallback? onViewSession,
  required VoidCallback? onViewTrace,
  required VoidCallback? onForkSession,
  required VoidCallback? onCopyToAgent,
  required VoidCallback? onResetSession,
}) {
  return [
    if (!isCurrentSession && onViewSession != null)
      _SessionRowAction(
        value: 'viewSession',
        icon: Icons.chat_outlined,
        label: l10n.chat_viewSession,
      ),
    if (onViewTrace != null)
      _SessionRowAction(
        value: 'viewTrace',
        icon: Icons.psychology_outlined,
        label: l10n.chat_viewTrace,
      ),
    if (onForkSession != null)
      _SessionRowAction(
        value: 'fork',
        icon: Icons.call_split,
        label: l10n.chat_forkSession,
      ),
    if (onCopyToAgent != null)
      _SessionRowAction(
        value: 'copyToAgent',
        icon: Icons.drive_file_move_outline,
        label: l10n.chat_copySessionTo,
      ),
    if (isCurrentSession && onResetSession != null)
      _SessionRowAction(
        value: 'reset',
        icon: Icons.refresh,
        label: l10n.chat_resetSession,
      ),
    _SessionRowAction(
      value: 'copyInfo',
      icon: Icons.copy_all,
      label: l10n.chat_copySessionInfo,
    ),
  ];
}

Future<void> _applySessionRowAction(
  BuildContext context, {
  required String? action,
  required Channel session,
  required String displayTitle,
  required VoidCallback? onViewSession,
  required VoidCallback? onViewTrace,
  required VoidCallback? onForkSession,
  required VoidCallback? onCopyToAgent,
  required VoidCallback? onResetSession,
}) async {
  if (!context.mounted || action == null) return;
  final l10n = AppLocalizations.of(context);
  switch (action) {
    case 'viewSession':
      onViewSession?.call();
    case 'viewTrace':
      onViewTrace?.call();
    case 'fork':
      onForkSession?.call();
    case 'copyToAgent':
      onCopyToAgent?.call();
    case 'reset':
      onResetSession?.call();
    case 'copyInfo':
      await _copyText(
        context,
        l10n.chat_copySessionInfoPayload(
          displayTitle,
          session.id,
          SessionUtils.familyChannelId(session),
        ),
      );
  }
}

String _displayTitle(Channel session, String? sessionTitle) {
  final title = (sessionTitle ?? session.name).trim();
  return title.isEmpty ? session.name : title;
}

/// 移动端：长按会话行弹出底部菜单。会等到 bottom sheet 完全关闭后再
/// 执行对应回调，因此调用方在回调里再关抽屉/导航不会与退场动画打架。
Future<void> showSessionRowMenu(
  BuildContext context, {
  required Channel session,
  String? sessionTitle,
  required bool isCurrentSession,
  VoidCallback? onViewSession,
  VoidCallback? onViewTrace,
  VoidCallback? onForkSession,
  VoidCallback? onCopyToAgent,
  VoidCallback? onResetSession,
}) async {
  final l10n = AppLocalizations.of(context);
  final actions = _sessionRowActions(
    l10n: l10n,
    isCurrentSession: isCurrentSession,
    onViewSession: onViewSession,
    onViewTrace: onViewTrace,
    onForkSession: onForkSession,
    onCopyToAgent: onCopyToAgent,
    onResetSession: onResetSession,
  );
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in actions)
              ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                onTap: () => Navigator.pop(sheetContext, item.value),
              ),
          ],
        ),
      );
    },
  );
  if (!context.mounted) return;
  await _applySessionRowAction(
    context,
    action: action,
    session: session,
    displayTitle: _displayTitle(session, sessionTitle),
    onViewSession: onViewSession,
    onViewTrace: onViewTrace,
    onForkSession: onForkSession,
    onCopyToAgent: onCopyToAgent,
    onResetSession: onResetSession,
  );
}

/// 桌面端：在「更多」按钮旁弹出下拉菜单。
Future<void> showSessionRowPopupMenu(
  BuildContext context, {
  required BuildContext buttonContext,
  required Channel session,
  String? sessionTitle,
  required bool isCurrentSession,
  VoidCallback? onViewSession,
  VoidCallback? onViewTrace,
  VoidCallback? onForkSession,
  VoidCallback? onCopyToAgent,
  VoidCallback? onResetSession,
}) async {
  final overlayBox =
      Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
  final buttonBox = buttonContext.findRenderObject() as RenderBox?;
  if (overlayBox == null || buttonBox == null || !buttonBox.hasSize) return;

  final rect = overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero)) &
      buttonBox.size;
  final l10n = AppLocalizations.of(context);
  final actions = _sessionRowActions(
    l10n: l10n,
    isCurrentSession: isCurrentSession,
    onViewSession: onViewSession,
    onViewTrace: onViewTrace,
    onForkSession: onForkSession,
    onCopyToAgent: onCopyToAgent,
    onResetSession: onResetSession,
  );
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromSize(rect, overlayBox.size),
    constraints: const BoxConstraints(
      minWidth: 2.0 * 56.0,
      maxWidth: 5.0 * 56.0,
      maxHeight: 280,
    ),
    items: [
      for (final item in actions)
        PopupMenuItem<String>(
          value: item.value,
          child: Row(
            children: [
              Icon(item.icon, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(item.label)),
            ],
          ),
        ),
    ],
  );
  if (!context.mounted) return;
  await _applySessionRowAction(
    context,
    action: action,
    session: session,
    displayTitle: _displayTitle(session, sessionTitle),
    onViewSession: onViewSession,
    onViewTrace: onViewTrace,
    onForkSession: onForkSession,
    onCopyToAgent: onCopyToAgent,
    onResetSession: onResetSession,
  );
}

Future<void> _copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showTopToast(
    context,
    AppLocalizations.of(context).chat_copiedToClipboard,
    icon: Icons.check_circle,
    color: Colors.green,
  );
}

/// 桌面端会话行 hover：把右侧日期换成「更多」，菜单打开期间保持图标。
class SessionRowHoverHost extends StatefulWidget {
  final bool enabled;
  final Widget Function(BuildContext context, SessionRowHoverState hover)
      builder;

  const SessionRowHoverHost({
    super.key,
    required this.enabled,
    required this.builder,
  });

  @override
  State<SessionRowHoverHost> createState() => _SessionRowHoverHostState();
}

class SessionRowHoverState {
  const SessionRowHoverState({
    required this.showMore,
    required this.holdWhileOpen,
  });

  final bool showMore;
  final Future<void> Function(Future<void> Function() action) holdWhileOpen;
}

class _SessionRowHoverHostState extends State<SessionRowHoverHost> {
  bool _hovered = false;
  bool _menuOpen = false;

  Future<void> _holdWhileOpen(Future<void> Function() action) async {
    setState(() => _menuOpen = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _menuOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hover = SessionRowHoverState(
      showMore: widget.enabled && (_hovered || _menuOpen),
      holdWhileOpen: _holdWhileOpen,
    );
    final child = widget.builder(context, hover);
    if (!widget.enabled) return child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: child,
    );
  }
}

/// 会话行右侧：默认日期；桌面 hover 后换成更多按钮。
Widget? sessionRowTrailing({
  required BuildContext context,
  required bool showMore,
  required String timeText,
  Widget? above,
  Future<void> Function(BuildContext buttonContext)? onMorePressed,
}) {
  final more = onMorePressed == null
      ? null
      : Builder(
          builder: (buttonContext) {
            return IconButton(
              key: const Key('session_row_more'),
              tooltip: AppLocalizations.of(context).chat_moreActions,
              icon: const Icon(Icons.more_vert, size: 20),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => onMorePressed(buttonContext),
            );
          },
        );
  final time = timeText.isEmpty
      ? null
      : Text(
          timeText,
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        );
  final end = showMore ? more : time;
  if (above == null && end == null) return null;
  if (above == null) return end;
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      above,
      if (end != null) end,
    ],
  );
}
