import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'chat_panel_scope.dart';

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
/// 纯布局组件，不感知群聊/单聊模式：调用方（ChatScreen）构造 header 和
/// 底部操作；搜索框为真实输入框。提交给 [bodyBuilder] 的查询与对话列表
/// 搜索一样是惰性的：连续输入只在停手 300ms 后提交一次，清空立刻回到
/// 完整列表。调用方按 query 过滤并返回面板，搜索不出抽屉。
///
/// 除搜索输入外，所有点击（关闭、header、底部操作）统一先经
/// [closePanelRoute] 关闭面板再执行回调：抽屉形态 pop 抽屉路由，避免
/// 调用方持有 ChatScreen 的 context 误 pop 掉聊天页路由；停靠（固定）
/// 形态由外层 [ChatPanelScope] 接管，面板保留不动。
class ChatMoreDrawer extends StatefulWidget {
  /// 头像 + 名称行（调用方构造），点击整个区域触发 [headerOnTap]。
  final Widget header;

  /// 点头像/名称区域 → 查看详情（先关抽屉再回调）。
  final VoidCallback? headerOnTap;

  /// header 尾部小按钮（单聊：编辑 Agent；群聊：群成员）。
  /// 组件负责渲染按钮并先关抽屉再回调，避免按钮点击时抽屉仍叠在上层。
  final IconData? headerTrailingIcon;
  final String? headerTrailingTooltip;
  final VoidCallback? onHeaderTrailing;

  /// 搜索框提示文案。
  final String searchHint;

  /// 已提交的搜索词变化时重建 body：调用方按 query 过滤会话列表。
  /// 空查询表示完整列表。输入过程中不会逐字调用。
  final Widget Function(BuildContext context, String query) bodyBuilder;

  final List<ChatDrawerAction> footerActions;

  /// 是否已固定为停靠面板（钉住图标呈按下态）。
  final bool pinned;

  /// 钉住按钮回调；为 null 时不显示（移动端抽屉无固定能力）。
  final VoidCallback? onPinToggle;

  /// 关闭按钮回调；为 null 时退回 pop 当前路由（抽屉形态）。
  final VoidCallback? onClose;

  const ChatMoreDrawer({
    super.key,
    required this.header,
    this.headerOnTap,
    this.headerTrailingIcon,
    this.headerTrailingTooltip,
    this.onHeaderTrailing,
    required this.searchHint,
    required this.bodyBuilder,
    this.footerActions = const [],
    this.pinned = false,
    this.onPinToggle,
    this.onClose,
  });

  @override
  State<ChatMoreDrawer> createState() => _ChatMoreDrawerState();
}

class _ChatMoreDrawerState extends State<ChatMoreDrawer> {
  /// 与对话列表搜索同一窗口：停手后才把查询交给 body，
  /// 避免每敲一个字符就扫一遍消息。
  static const _searchDebounce = Duration(milliseconds: 300);

  final _searchController = TextEditingController();

  /// 输入框非空（只驱动清除按钮，不触发搜索）。
  bool _hasInput = false;

  /// 已经提交给 [ChatMoreDrawer.bodyBuilder] 的查询。
  String _committedQuery = '';

  Timer? _searchDebounceTimer;

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    final active = value.trim().isNotEmpty;
    _searchDebounceTimer?.cancel();
    if (!active) {
      if (_hasInput || _committedQuery.isNotEmpty) {
        setState(() {
          _hasInput = false;
          _committedQuery = '';
        });
      }
      return;
    }
    if (!_hasInput) {
      setState(() => _hasInput = true);
    }
    _searchDebounceTimer = Timer(_searchDebounce, () {
      if (!mounted) return;
      final q = _searchController.text.trim();
      if (q.isEmpty || q == _committedQuery) return;
      setState(() => _committedQuery = q);
    });
  }

  /// 清除按钮改的是 controller，不会走 [TextField.onChanged]，要自己提交空查询。
  void _clearSearch() {
    _searchDebounceTimer?.cancel();
    _searchController.clear();
    if (!_hasInput && _committedQuery.isEmpty) return;
    setState(() {
      _hasInput = false;
      _committedQuery = '';
    });
  }

  void _popThen(BuildContext context, VoidCallback? action) {
    closePanelRoute(context);
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

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
                  onTap: widget.headerOnTap == null
                      ? null
                      : () => _popThen(context, widget.headerOnTap),
                  behavior: HitTestBehavior.opaque,
                  child: widget.header,
                ),
              ),
              if (widget.headerTrailingIcon != null)
                IconButton(
                  icon: Icon(widget.headerTrailingIcon, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  visualDensity: VisualDensity.compact,
                  tooltip: widget.headerTrailingTooltip,
                  onPressed: widget.onHeaderTrailing == null
                      ? null
                      : () => _popThen(context, widget.onHeaderTrailing),
                ),
              // 钉住：固定为右侧停靠面板（仅桌面）。放在关闭键左侧，
              // 与 header 尾部小按钮成组。
              if (widget.onPinToggle != null)
                IconButton(
                  icon: Icon(
                    widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                    color: widget.pinned
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  visualDensity: VisualDensity.compact,
                  tooltip: widget.pinned
                      ? l10n.chat_unpinPanel
                      : l10n.chat_pinPanel,
                  onPressed: widget.onPinToggle,
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                visualDensity: VisualDensity.compact,
                tooltip: l10n.common_close,
                onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        // ── 搜索栏：停手后才把查询提交给 body ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: widget.searchHint,
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                if (_hasInput)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.common_clear,
                    onPressed: _clearSearch,
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // ── 会话列表（按已提交的搜索词过滤）──
        Expanded(
          child: widget.bodyBuilder(context, _committedQuery),
        ),
        // ── 底部操作 ──
        if (widget.footerActions.isNotEmpty) ...[
          const Divider(height: 1),
          for (final action in widget.footerActions)
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
