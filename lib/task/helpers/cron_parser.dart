
/// Utilities for parsing and working with cron expressions and ISO 8601 durations.
class CronParser {
  /// Parse a cron expression and validate its format.
  /// 
  /// Returns true if the cron expression is valid, false otherwise.
  /// 
  /// Cron format: minute hour day month dayOfWeek
  /// Example: "0 9 * * *" (9am every day)
  static bool isValidCron(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return false;

    // Check each part is either * or a number/range/list
    for (final part in parts) {
      if (!_isValidCronPart(part)) return false;
    }
    return true;
  }

  /// Parse an ISO 8601 duration string and return as Duration.
  /// 
  /// Examples:
  /// - "PT5M" -> 5 minutes
  /// - "PT1H" -> 1 hour
  /// - "PT30S" -> 30 seconds
  /// - "P1D" -> 1 day
  /// - "PT1H30M" -> 1 hour 30 minutes
  static Duration? parseIsoDuration(String durationStr) {
    try {
      // ISO 8601 duration pattern: P[n]D[T[n]H[n]M[n]S]
      final pattern = RegExp(
        r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
      );

      final match = pattern.firstMatch(durationStr.toUpperCase());
      if (match == null) return null;

      final days = int.tryParse(match.group(1) ?? '0') ?? 0;
      final hours = int.tryParse(match.group(2) ?? '0') ?? 0;
      final minutes = int.tryParse(match.group(3) ?? '0') ?? 0;
      final seconds = double.tryParse(match.group(4) ?? '0') ?? 0;

      return Duration(
        days: days,
        hours: hours,
        minutes: minutes,
        seconds: seconds.toInt(),
        milliseconds: ((seconds % 1) * 1000).toInt(),
      );
    } catch (e) {
      return null;
    }
  }

  /// Calculate the next run time based on a cron expression.
  ///
  /// Returns the next fire time in milliseconds, or `null` if the expression
  /// is invalid or no matching time is found within 4 years.
  ///
  /// **Never** returns [fromTime] itself as a fallback — callers must handle
  /// a `null` result explicitly to avoid accidental immediate execution.
  ///
  /// This is a simplified implementation that handles basic cron patterns.
  /// For complex patterns, consider using a dedicated cron library.
  static int? calculateNextCronRun(String cronExpression, {int? fromTime}) {
    fromTime ??= DateTime.now().millisecondsSinceEpoch;
    final from = DateTime.fromMillisecondsSinceEpoch(fromTime);

    final parts = cronExpression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return null;

    // Validate each field before iterating.
    if (!isValidCron(cronExpression)) return null;

    final minute = parts[0];
    final hour = parts[1];
    final dayOfMonth = parts[2];
    final month = parts[3];
    final dayOfWeek = parts[4];

    // Start from next minute to ensure we never fire at the exact creation time.
    var next = DateTime(from.year, from.month, from.day, from.hour, from.minute)
        .add(const Duration(minutes: 1));

    // Search for next valid time (up to 4 years in the future as a safety limit)
    final maxTime = DateTime.now().add(const Duration(days: 4 * 365));

    while (next.isBefore(maxTime)) {
      if (_matchesCronPart(next.minute, minute) &&
          _matchesCronPart(next.hour, hour) &&
          _matchesCronPart(next.day, dayOfMonth) &&
          _matchesCronPart(next.month, month) &&
          _matchesCronDayOfWeek(next.weekday, dayOfWeek)) {
        return next.millisecondsSinceEpoch;
      }
      next = next.add(const Duration(minutes: 1));
    }

    // No match found within 4 years — return null so callers can handle it safely.
    return null;
  }

  /// Calculate the next run time for an interval duration.
  static int calculateNextIntervalRun(Duration interval, {int? fromTime}) {
    fromTime ??= DateTime.now().millisecondsSinceEpoch;
    final from = DateTime.fromMillisecondsSinceEpoch(fromTime);
    return from.add(interval).millisecondsSinceEpoch;
  }

  /// Get a human-readable description of a cron expression.
  /// 
  /// Examples:
  /// - "0 9 * * *" -> "Daily at 9:00 AM"
  /// - "0 */2 * * *" -> "Every 2 hours"
  /// - "0 9 * * 1-5" -> "Weekdays at 9:00 AM"
  static String describeCron(String cronExpression) {
    final parts = cronExpression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return 'Invalid cron expression';

    final minute = parts[0];
    final hour = parts[1];
    final dayOfMonth = parts[2];
    final month = parts[3];
    final dayOfWeek = parts[4];

    // Simple patterns
    if (minute == '0' && hour == '*' && dayOfMonth == '*' && month == '*' && dayOfWeek == '*') {
      return 'Every hour';
    }

    if (minute == '0' && dayOfMonth == '*' && month == '*' && dayOfWeek == '*') {
      if (hour == '*') {
        return 'Every hour';
      } else if (hour.contains(',')) {
        return 'Multiple times daily';
      } else if (hour.contains('-')) {
        return 'During specific hours';
      } else {
        try {
          final h = int.parse(hour);
          return 'Daily at ${h.toString().padLeft(2, '0')}:00';
        } catch (e) {
          return 'Daily';
        }
      }
    }

    if (dayOfMonth == '*' && month == '*') {
      if (dayOfWeek == '1-5') {
        if (hour != '*') {
          try {
            final h = int.parse(hour);
            return 'Weekdays at ${h.toString().padLeft(2, '0')}:00';
          } catch (e) {
            return 'Weekdays';
          }
        }
        return 'Weekdays';
      }
    }

    return cronExpression;
  }

  /// Get a human-readable description of an ISO 8601 duration.
  static String describeDuration(String durationStr) {
    final duration = parseIsoDuration(durationStr);
    if (duration == null) return 'Invalid duration';

    final parts = <String>[];
    
    if (duration.inDays > 0) {
      parts.add('${duration.inDays} day${duration.inDays > 1 ? 's' : ''}');
    }
    
    final remainingHours = (duration.inHours % 24);
    if (remainingHours > 0) {
      parts.add('$remainingHours hour${remainingHours > 1 ? 's' : ''}');
    }
    
    final remainingMinutes = (duration.inMinutes % 60);
    if (remainingMinutes > 0) {
      parts.add('$remainingMinutes minute${remainingMinutes > 1 ? 's' : ''}');
    }
    
    final remainingSeconds = (duration.inSeconds % 60);
    if (remainingSeconds > 0 || parts.isEmpty) {
      parts.add('$remainingSeconds second${remainingSeconds > 1 ? 's' : ''}');
    }

    if (parts.length == 1) return parts[0];
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    
    return parts.sublist(0, parts.length - 1).join(', ') + ' and ' + parts.last;
  }

  /// Check if a specific value matches a cron part pattern.
  /// 
  /// Patterns:
  /// - "*" matches any value
  /// - "5" matches exactly 5
  /// - "5,10,15" matches 5, 10, or 15
  /// - "5-10" matches 5 through 10
  /// - "*/5" matches every 5th value
  /// - "5-20/5" matches every 5th value between 5 and 20
  static bool _matchesCronPart(int value, String pattern) {
    if (pattern == '*') return true;

    // Handle step values (*/n or start-end/n)
    if (pattern.contains('/')) {
      final parts = pattern.split('/');
      final step = int.tryParse(parts[1]) ?? 1;

      if (parts[0] == '*') {
        return value % step == 0;
      } else if (parts[0].contains('-')) {
        final rangeParts = parts[0].split('-');
        final start = int.tryParse(rangeParts[0]) ?? 0;
        final end = int.tryParse(rangeParts[1]) ?? 59;
        return value >= start && value <= end && (value - start) % step == 0;
      }
      return value % step == 0;
    }

    // Handle ranges
    if (pattern.contains('-')) {
      final parts = pattern.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = int.tryParse(parts[1]) ?? 59;
      return value >= start && value <= end;
    }

    // Handle lists
    if (pattern.contains(',')) {
      final values = pattern.split(',').map((s) => int.tryParse(s.trim()) ?? -1).toList();
      return values.contains(value);
    }

    // Handle single value
    final singleValue = int.tryParse(pattern);
    return singleValue != null && singleValue == value;
  }

  /// Check if a day of week matches the cron pattern.
  /// 
  /// Cron uses 0-6 or 1-7 (0 or 7 = Sunday)
  /// DateTime uses 1-7 (1 = Monday, 7 = Sunday)
  static bool _matchesCronDayOfWeek(int dateTimeWeekday, String pattern) {
    if (pattern == '*') return true;

    // Convert DateTime weekday (1=Mon, 7=Sun) to cron format (0=Sun, 1=Mon, ..., 6=Sat)
    int cronWeekday = dateTimeWeekday == 7 ? 0 : dateTimeWeekday;

    // Handle step values
    if (pattern.contains('/')) {
      final parts = pattern.split('/');
      final step = int.tryParse(parts[1]) ?? 1;
      return cronWeekday % step == 0;
    }

    // Handle ranges (may wrap around, e.g., "5-1" means Fri-Mon)
    if (pattern.contains('-')) {
      final parts = pattern.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = int.tryParse(parts[1]) ?? 6;

      if (start <= end) {
        return cronWeekday >= start && cronWeekday <= end;
      } else {
        // Wrap around (e.g., 5-1 = Fri, Sat, Sun, Mon)
        return cronWeekday >= start || cronWeekday <= end;
      }
    }

    // Handle lists
    if (pattern.contains(',')) {
      final values = pattern.split(',').map((s) => int.tryParse(s.trim()) ?? -1).toList();
      return values.contains(cronWeekday);
    }

    // Handle single value
    final singleValue = int.tryParse(pattern);
    return singleValue != null && (singleValue == cronWeekday || (singleValue == 7 && cronWeekday == 0));
  }

  /// Validate a single cron part.
  static bool _isValidCronPart(String part) {
    if (part == '*') return true;

    // Handle step values
    if (part.contains('/')) {
      final stepStr = part.split('/').last;
      return int.tryParse(stepStr) != null;
    }

    // Handle ranges
    if (part.contains('-')) {
      final rangeParts = part.split('-');
      if (rangeParts.length != 2) return false;
      return int.tryParse(rangeParts[0]) != null && int.tryParse(rangeParts[1]) != null;
    }

    // Handle lists
    if (part.contains(',')) {
      final values = part.split(',');
      return values.every((v) => int.tryParse(v.trim()) != null);
    }

    // Single number
    return int.tryParse(part) != null;
  }
}
