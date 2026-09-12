import 'package:flutter/scheduler.dart';

import 'logger_service.dart';

/// 慢帧埋点：把超预算的帧写进 [LoggerService]，供应用内「日志」页导出。
///
/// 存在的理由：手机上「划开抽屉顿一下」这类问题只能在真机上复现，而这里
/// 既没有设备也拿不到手机的帧耗时 —— 只能靠现场把数据带回来。
///
/// 只在超阈值时写日志（默认 build+raster ≥ 32ms，即 60fps 下至少掉一帧），
/// 正常帧不开销。用户装的是 release 包，所以埋点不能只在 debug 生效，否则
/// 永远测不到。
///
/// 一个 timings 批次聚合成一行：慢帧往往连着来（一次卡顿掉 3~8 帧），
/// 逐帧写会把日志刷爆，也看不出这是一次卡顿。
class FrameTimingMonitor {
  FrameTimingMonitor({
    this.threshold = const Duration(milliseconds: 32),
    LoggerService? logger,
  }) : _log = logger ?? LoggerService();

  /// 单帧 build + raster 达到它就算慢帧（默认 32ms：60fps 下已掉一帧）。
  final Duration threshold;

  final LoggerService _log;

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    final summary = summarizeSlowFrames(timings, threshold);
    if (summary != null) _log.warning(summary, tag: 'Perf');
  }

  /// 把一批帧耗时聚合成一行；没有慢帧时返回 null。
  ///
  /// 慢帧的成因分两类，分开报：build 高是 UI isolate 在忙（重建/解析/查库
  /// 回调），raster 高是 GPU 侧（图层太复杂、图片解码）。看错方向会白忙。
  static String? summarizeSlowFrames(
    List<FrameTiming> timings,
    Duration threshold,
  ) {
    if (timings.isEmpty) return null;

    final slow = timings
        .where((t) => t.buildDuration + t.rasterDuration >= threshold)
        .toList();
    if (slow.isEmpty) return null;

    var worst = slow.first;
    var buildTotal = Duration.zero;
    var rasterTotal = Duration.zero;
    for (final t in slow) {
      if (t.buildDuration + t.rasterDuration >
          worst.buildDuration + worst.rasterDuration) {
        worst = t;
      }
      buildTotal += t.buildDuration;
      rasterTotal += t.rasterDuration;
    }
    final allTotal = buildTotal + rasterTotal;

    return '慢帧 ${slow.length}/${timings.length} 帧：'
        '最差 ${_ms(worst.buildDuration + worst.rasterDuration)}ms'
        '（build ${_ms(worst.buildDuration)} / raster ${_ms(worst.rasterDuration)}），'
        '平均 ${_ms(Duration(microseconds: allTotal.inMicroseconds ~/ slow.length))}ms，'
        'build 合计 ${_ms(buildTotal)}ms raster 合计 ${_ms(rasterTotal)}ms';
  }

  static int _ms(Duration d) => d.inMilliseconds;
}
