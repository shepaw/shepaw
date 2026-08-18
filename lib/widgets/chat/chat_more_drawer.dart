import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// 抽屉底部一个操作条目（储物空间 / 工作流 / 重置会话 等）。
class ChatDrawerAction {
  const ChatDrawerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// 纯回调：组件会先 pop 抽屉再调用，调用方无需关心抽屉关闭。
  final VoidCallback onTap;
}

/// 群聊 / 单聊「更多」右侧抽屉（豆包风格）。
///
/// 纯布局组件，不感知群聊/单聊模式：调用方（ChatScreen）构造 header、
/// 搜索入口和底部操作，body 直接嵌入会话列表面板
/// （[SessionListPanel] / [GroupSessionListPanel]），从而「更多」一点即见会话列表。
///
/// 所有点击（关闭、header、搜索栏、底部操作）统一先 pop 抽屉再执行回调，
/// 避免调用方持有 ChatScreen 的 context 误 pop 掉聊天页路由。
class ChatMoreDrawer extends StatelessWidget {
  /// 头像 + 名称行（调用方构造），点击整个区域触发 [headerOnTap]。
  final Widget header;

  /// 点头像/名称区域 → 查看详情（先关抽屉再回调）。
  final VoidCallback? headerOnTap;

  /// header 尾部小按钮（单聊：编辑 Agent；群聊：群成员）。
  /// 组件负责渲染按钮并先关抽屉再回调，避免按钮点击时抽屉仍叠在上层。
  final IconData? headerTrailingIcon;
  final String? headerTrailingTooltip;
  final VoidCallback? onHeaderTrailing;

  /// 搜索栏提示文案，点击打开消息搜索页。
  final String searchHint;

  final VoidCallback onSearch;

  /// 会话列表面板（drawer 主体，直接展示会话列表）。
  final Widget body;

  final List<ChatDrawerAction> footerActions;

  const ChatMoreDrawer({
    super.key,
    required this.header,
    this.headerOnTap,
    this.headerTrailingIcon,
    this.headerTrailingTooltip,
    this.onHeaderTrailing,
    required this.searchHint,
    required this.onSearch,
    required this.body,
    this.footerActions = const [],
  });

  void _popThen(BuildContext context, VoidCallback? action) {
    Navigator.of(context).pop();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 头部：头像 + 名称 + 尾部按钮 + 关闭 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: headerOnTap == null
                      ? null
                      : () => _popThen(context, headerOnTap),
                  behavior: HitTestBehavior.opaque,
                  child: header,
                ),
              ),
              if (headerTrailingIcon != null)
                IconButton(
                  icon: Icon(headerTrailingIcon, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  visualDensity: VisualDensity.compact,
                  tooltip: headerTrailingTooltip,
                  onPressed: onHeaderTrailing == null
                      ? null
                      : () => _popThen(context, onHeaderTrailing),
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                visualDensity: VisualDensity.compact,
                tooltip: l10n.common_close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        // ── 搜索栏 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _popThen(context, onSearch),
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        searchHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        // ── 会话列表 ──
        Expanded(child: body),
        // ── 底部操作 ──
        if (footerActions.isNotEmpty) ...[
          const Divider(height: 1),
          for (final action in footerActions)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(action.icon, size: 20),
              title: Text(
                action.label,
                style: const TextStyle(fontSize: 15),
              ),
              onTap: () => _popThen(context, action.onTap),
            ),
        ],
      ],
    );
  }
}
