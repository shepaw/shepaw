import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/frame_timing_monitor.dart';

/// 造一帧：build 用 [buildMs]，raster 用 [rasterMs]，其余时间戳给足。
FrameTiming frame({required int buildMs, required int rasterMs}) {
  const vsync = 0;
  const buildStart = vsync + 1000;
  final buildFinish = buildStart + buildMs * 1000;
  final rasterStart = buildFinish + 500;
  final rasterFinish = rasterStart + rasterMs * 1000;
  return FrameTiming(
    vsyncStart: vsync,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish + 100,
  );
}

const _threshold = Duration(milliseconds: 32);

void main() {
  group('FrameTimingMonitor.summarizeSlowFrames', () {
    test('全部达标时不产出日志', () {
      final summary = FrameTimingMonitor.summarizeSlowFrames([
        frame(buildMs: 2, rasterMs: 3),
        frame(buildMs: 1, rasterMs: 1),
        frame(buildMs: 10, rasterMs: 5),
      ], _threshold);
      expect(summary, isNull);
    });

    test('空批次不产出日志', () {
      expect(FrameTimingMonitor.summarizeSlowFrames([], _threshold), isNull);
    });

    test('恰好等于阈值即算慢帧（32ms 在 60fps 下已经掉了一帧）', () {
      final summary = FrameTimingMonitor.summarizeSlowFrames(
        [frame(buildMs: 31, rasterMs: 1)],
        _threshold,
      );
      expect(summary, isNotNull);
      expect(summary, contains('最差 32ms'));
    });

    test('差一点点不算（31ms）', () {
      final summary = FrameTimingMonitor.summarizeSlowFrames(
        [frame(buildMs: 30, rasterMs: 1)],
        _threshold,
      );
      expect(summary, isNull);
    });

    test('一次卡顿聚合成一行：帧数、最差、平均、build/raster 分列', () {
      final summary = FrameTimingMonitor.summarizeSlowFrames([
        frame(buildMs: 2, rasterMs: 3), // 正常帧，不计入慢帧
        frame(buildMs: 62, rasterMs: 25), // 最差：87ms
        frame(buildMs: 40, rasterMs: 10), // 50ms
      ], _threshold);

      expect(summary, isNotNull);
      expect(summary, contains('慢帧 2/3 帧'));
      expect(summary, contains('最差 87ms（build 62 / raster 25）'));
      // (87 + 50) / 2 = 68.5 → 68
      expect(summary, contains('平均 68ms'));
      expect(summary, contains('build 合计 102ms'));
      expect(summary, contains('raster 合计 35ms'));
    });

    test('raster 主导的卡顿也能看出来（不是只有 build 才算）', () {
      final summary = FrameTimingMonitor.summarizeSlowFrames(
        [frame(buildMs: 3, rasterMs: 90)],
        _threshold,
      );
      expect(summary, contains('最差 93ms（build 3 / raster 90）'));
    });
  });
}
