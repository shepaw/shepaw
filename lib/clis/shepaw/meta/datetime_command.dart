import '../../cli_base.dart';

/// 返回设备当前时间和时区信息
class MetaDatetimeCommand extends CliCommand {
  @override
  String get name => 'datetime';

  @override
  String get description => 'Return current date, time and timezone info';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final now = DateTime.now();
    final weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday'
    ];
    final weekdaysCN = [
      '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'
    ];
    final tzOffset = now.timeZoneOffset;
    final sign = tzOffset.isNegative ? '-' : '+';
    final hh = tzOffset.inHours.abs().toString().padLeft(2, '0');
    final mm = (tzOffset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return {
      'iso8601': now.toIso8601String(),
      'date':
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'time':
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      'weekday_en': weekdays[now.weekday - 1],
      'weekday_cn': weekdaysCN[now.weekday - 1],
      'timezone_offset': '$sign$hh:$mm',
      'timezone_name': now.timeZoneName,
      'unix_ms': now.millisecondsSinceEpoch,
    };
  }
}
