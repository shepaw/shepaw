import 'package:flutter/material.dart';

/// 会话面板（右侧抽屉 / 停靠面板）条目点击时的关闭语义。
///
/// 同一份会话列表内容（[ChatMoreDrawer] 及其子面板）在两种形态下复用：
/// - 抽屉模式：条目点击后需要 pop 抽屉路由；
/// - 停靠模式（固定面板）：面板保留，没有可 pop 的路由 —— 此时若仍
///   `Navigator.pop` 会误关聊天页路由。
///
/// 停靠形态由 [ChatScreen] 在面板外层包一个 [ChatPanelScope]（回调为空
/// 操作）；抽屉形态不包 scope，[closePanelRoute] 退回原来的
/// `Navigator.pop` 行为，旧路径无需逐处包 scope。
class ChatPanelScope extends InheritedWidget {
  const ChatPanelScope({
    super.key,
    required super.child,
    required this.popRouteIfAny,
  });

  /// 关闭当前面板形态的路由：抽屉 → `Navigator.pop`；停靠 → 空操作。
  final VoidCallback popRouteIfAny;

  static ChatPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatPanelScope>();

  @override
  bool updateShouldNotify(ChatPanelScope oldWidget) =>
      popRouteIfAny != oldWidget.popRouteIfAny;
}

/// 条目点击后关闭面板：停靠面板（有 scope）保留不动，否则 pop 当前路由
/// （抽屉模式的历史行为）。
void closePanelRoute(BuildContext context) {
  final scope = ChatPanelScope.maybeOf(context);
  if (scope != null) {
    scope.popRouteIfAny();
    return;
  }
  Navigator.of(context).pop();
}
