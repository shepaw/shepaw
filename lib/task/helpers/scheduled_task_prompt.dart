import '../models/scheduled_task.dart';

/// User-visible + model-facing copy for a scheduled group trigger.
class ScheduledTaskPrompt {
  ScheduledTaskPrompt._();

  /// Group user-message body: the instruction plus a short automated-trigger
  /// note so the admin does not wait for a live user who is not online.
  static String groupUserContent(ScheduledTask task, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final timeStr =
        '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}'
        ' ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final title = task.description.trim().isNotEmpty
        ? task.description.trim()
        : '定时任务';
    return '⏰ $title（$timeStr 自动触发）\n\n'
        '${task.instruction}\n\n'
        '[系统] 这是定时任务自动发送，用户未必在线。请直接执行，不要追问澄清。';
  }
}
