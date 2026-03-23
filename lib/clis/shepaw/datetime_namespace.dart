import '../cli_base.dart';

/// datetime 命名空间 - 返回设备当前时间
class DatetimeNamespace extends CliNamespace {
  static final instance = DatetimeNamespace._();
  DatetimeNamespace._();

  @override
  String get namespace => 'datetime';

  @override
  String get description => 'Current date and time (device local timezone)';

  @override
  Map<String, CliCommand> get commands => {};

  /// datetime 没有子命令，直接执行
  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    final now = DateTime.now();
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final weekdaysCN = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    final tzOffset = now.timeZoneOffset;
    final sign = tzOffset.isNegative ? '-' : '+';
    final hh = tzOffset.inHours.abs().toString().padLeft(2, '0');
    final mm = (tzOffset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return {
      'iso8601': now.toIso8601String(),
      'date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'time': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      'weekday_en': weekdays[now.weekday - 1],
      'weekday_cn': weekdaysCN[now.weekday - 1],
      'timezone_offset': '$sign$hh:$mm',
      'timezone_name': now.timeZoneName,
      'unix_ms': now.millisecondsSinceEpoch,
    };
  }

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {'(no subcommand needed)': 'Returns current time directly'},
    'examples': ['shepaw datetime'],
  };
}
