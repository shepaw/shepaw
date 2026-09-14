import 'package:flutter/material.dart';

/// 「事件仅存在内存中」提示条。
///
/// `busStore` 上限 1000 条且静默驱逐，`inboxStore` / `_leases` / `_subscriptions`
/// 都随进程消失；只有 `persistent: true` 的订阅会被恢复。收件箱与最近事件
/// 两处必须让用户知道看到的不是全量历史。
class EventMemoryOnlyBanner extends StatelessWidget {
  final String text;

  const EventMemoryOnlyBanner({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Colors.grey.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: Colors.grey[600]),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表空态提示。
class EventEmptyHint extends StatelessWidget {
  final String text;
  final IconData icon;

  const EventEmptyHint({
    super.key,
    required this.text,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

/// `HH:mm:ss`，事件行内紧凑展示用（日期对「本次运行」的内存态没有意义）。
String formatEventClock(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}
